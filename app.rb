require 'rack'
require 'faye/websocket'
require 'thread'
require 'json'
require 'jwt'
require 'bcrypt'
require 'securerandom'
require 'sequel'

# Initialize SQLite DB and users table
DB = Sequel.sqlite(File.join(__dir__, 'db.sqlite3'))
unless DB.table_exists?(:users)
  DB.create_table :users do
    primary_key :id
    String :username, null: false, unique: true
    String :password_hash, null: false
    DateTime :created_at, null: false
  end
end

USERS = DB[:users]
unless DB.table_exists?(:games)
  DB.create_table :games do
    primary_key :id
    String :name
    String :status, default: 'open'
    Integer :capacity, default: 2
    Text :state
    DateTime :created_at, null: false
  end
end
unless DB.table_exists?(:games)
  DB.create_table :games do
    primary_key :id
    String :name
    String :status, default: 'open'
    Integer :capacity, default: 2
    DateTime :created_at, null: false
  end
end

unless DB.table_exists?(:players)
  DB.create_table :players do
    primary_key :id
    foreign_key :game_id, :games
    String :username, null: false
    DateTime :joined_at, null: false
  end
end

GAMES = DB[:games]
PLAYERS = DB[:players]

unless DB.table_exists?(:scores)
  DB.create_table :scores do
    primary_key :id
    String :username, null: false
    Integer :game_id
    Integer :score, null: false
    DateTime :created_at, null: false
  end
end

SCORES = DB[:scores]

# Ensure 'state' column exists on older DBs
if DB.table_exists?(:games) && !GAMES.columns.include?(:state)
  DB.alter_table :games do
    add_column :state, String
  end
end

class App
  KEEPALIVE_TIME = 15 # seconds
  SECRET = ENV['NEXUS_SECRET'] || 'change-me-please'

  @@clients = {}
  @@users = {}
  @@mutex = Mutex.new

  def call(env)
    req = Rack::Request.new(env)

    # WebSocket endpoint
    if req.path == '/ws' && Faye::WebSocket.websocket?(env)
      params = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
      token = params['token']
      game_id = params['game_id']

      user = verify_token(token)

      ws = Faye::WebSocket.new(env, nil, {ping: KEEPALIVE_TIME})

      unless user
        ws.on :open do |_|
          ws.close(4003, 'unauthorized')
        end
        return ws.rack_response
      end

      client_id = SecureRandom.uuid
      @@mutex.synchronize { @@clients[client_id] = { ws: ws, user: user, game_id: game_id } }

      ws.on :message do |event|
        begin
          data = JSON.parse(event.data)
        rescue
          data = { 'type' => 'message', 'data' => event.data }
        end

        payload = { from: user['username'], type: data['type'] || 'message', data: data['data'], game_id: game_id }

        # handle move/state messages by persisting game state
        if data['type'] == 'move' && game_id
          begin
            GAMES.where(id: game_id).update(state: JSON.generate(data['data']))
          rescue
          end
        end

        @@mutex.synchronize do
          @@clients.each do |_, c|
            next unless c[:game_id] && game_id && c[:game_id].to_s == game_id.to_s
            begin
              c[:ws].send(JSON.generate(payload))
            rescue
            end
          end
        end
      end

      ws.on :close do |_|
        @@mutex.synchronize { @@clients.delete(client_id) }
        ws = nil
      end

      return ws.rack_response
    end

    # REST endpoints: register, login
    case [req.request_method, req.path]
    when ['POST', '/register']
      body = parse_json(req)
      username = body['username']&.strip
      password = body['password']

      unless username && password && username.length >= 3 && password.length >= 4
        return json_response(422, error: 'invalid username or password')
      end

      begin
        pw_hash = BCrypt::Password.create(password)
        USERS.insert(username: username, password_hash: pw_hash.to_s, created_at: Time.now)
      rescue Sequel::UniqueConstraintViolation
        return json_response(409, error: 'user exists')
      end

      token = issue_token({ 'username' => username })
      json_response(201, username: username, token: token)

    when ['POST', '/login']
      body = parse_json(req)
      username = body['username']
      password = body['password']

      unless username && password
        return json_response(422, error: 'missing credentials')
      end

      db_user = USERS.where(username: username).first
      unless db_user && BCrypt::Password.new(db_user[:password_hash]) == password
        return json_response(401, error: 'invalid credentials')
      end

      token = issue_token({ 'username' => username })
      json_response(200, username: username, token: token)

    when ['POST', '/games']
      body = parse_json(req)
      name = body['name'] || "game-#{SecureRandom.hex(3)}"
      capacity = (body['capacity'] || 2).to_i
      id = GAMES.insert(name: name, status: 'open', capacity: capacity, created_at: Time.now)
      json_response(201, game_id: id, name: name, capacity: capacity)

    when ['POST', %r{^/games/([^/]+)/join$}]
      # dynamic join path: /games/:id/join
      m = req.path.match(%r{^/games/([^/]+)/join$})
      game_id = m[1]
      body = parse_json(req)
      username = body['username'] || verify_token(body['token'])&.[]('username')
      unless username
        return json_response(401, error: 'missing username or token')
      end

      game = GAMES.where(id: game_id).first
      return json_response(404, error: 'game not found') unless game

      count = PLAYERS.where(game_id: game_id).count
      if count >= game[:capacity]
        return json_response(409, error: 'game full')
      end

      PLAYERS.insert(game_id: game_id, username: username, joined_at: Time.now)
      players = PLAYERS.where(game_id: game_id).select_map(:username)

      # notify game clients that a player joined
      payload = { from: 'system', type: 'system', data: "#{username} joined", game_id: game_id }
      @@mutex.synchronize do
        @@clients.each do |_, c|
          next unless c[:game_id] && game_id && c[:game_id].to_s == game_id.to_s
          begin; c[:ws].send(JSON.generate(payload)); rescue; end
        end
      end

      json_response(200, game_id: game_id, players: players)

    when ['POST', '/matchmake']
      body = parse_json(req)
      username = body['username'] || verify_token(body['token'])&.[]('username')
      return json_response(401, error: 'missing username or token') unless username

      # find open game with available slot
      game = GAMES.where(status: 'open').order(:created_at).all.find do |g|
        PLAYERS.where(game_id: g[:id]).count < g[:capacity]
      end

      unless game
        id = GAMES.insert(name: "game-#{SecureRandom.hex(3)}", status: 'open', capacity: 2, created_at: Time.now)
        game = GAMES.where(id: id).first
      end

      PLAYERS.insert(game_id: game[:id], username: username, joined_at: Time.now)
      players = PLAYERS.where(game_id: game[:id]).select_map(:username)
      json_response(200, game_id: game[:id], players: players)

    when ['POST', '/score']
      body = parse_json(req)
      token_in_body = body['token']
      user = verify_token(token_in_body)
      return json_response(401, error: 'unauthorized') unless user
      score = (body['score'] || 0).to_i
      game_id = body['game_id']
      SCORES.insert(username: user['username'], game_id: game_id, score: score, created_at: Time.now)
      json_response(201, ok: true)

    when ['GET', '/leaderboard']
      params = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
      limit = (params['limit'] || 10).to_i
      rows = SCORES.order(Sequel.desc(:score)).limit(limit).all.map do |r|
        { username: r[:username], score: r[:score], game_id: r[:game_id], at: r[:created_at] }
      end
      json_response(200, leaderboard: rows)

    when ['GET', %r{^/leaderboard/game/([^/]+)$}]
      m = req.path.match(%r{^/leaderboard/game/([^/]+)$})
      gid = m[1]
      params = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
      limit = (params['limit'] || 10).to_i
      rows = SCORES.where(game_id: gid).order(Sequel.desc(:score)).limit(limit).all.map do |r|
        { username: r[:username], score: r[:score], at: r[:created_at] }
      end
      json_response(200, leaderboard: rows)

    when ['GET', '/games']
      # list open games with counts
      rows = GAMES.order(:created_at).all.map do |g|
        { id: g[:id], name: g[:name], status: g[:status], capacity: g[:capacity], players: PLAYERS.where(game_id: g[:id]).count }
      end
      json_response(200, games: rows)

    when ['POST', %r{^/games/([^/]+)/state$}]
      m = req.path.match(%r{^/games/([^/]+)/state$})
      game_id = m[1]
      body = parse_json(req)
      token_in_body = body['token']
      user = verify_token(token_in_body)
      return json_response(401, error: 'unauthorized') unless user

      state = body['state']
      GAMES.where(id: game_id).update(state: state)

      # broadcast system state update to game clients
      payload = { from: 'system', type: 'state', data: state, game_id: game_id }
      @@mutex.synchronize do
        @@clients.each do |_, c|
          next unless c[:game_id] && c[:game_id].to_s == game_id.to_s
          begin; c[:ws].send(JSON.generate(payload)); rescue; end
        end
      end

      json_response(200, game_id: game_id, state: state)

    when ['GET', %r{^/games/([^/]+)$}]
      m = req.path.match(%r{^/games/([^/]+)$})
      game_id = m[1]
      game = GAMES.where(id: game_id).first
      return json_response(404, error: 'game not found') unless game
      players = PLAYERS.where(game_id: game_id).select_map(:username)
      json_response(200, game_id: game_id, players: players, game: game)

    else
      [200, { 'Content-Type' => 'text/plain' }, ["Nexus Foward backend - websocket endpoint at /ws\n"]]
    end
  end

  private

  def parse_json(req)
    body = req.body.read
    return {} if body.nil? || body.strip == ''
    JSON.parse(body) rescue {}
  end

  def json_response(status, obj)
    [status, { 'Content-Type' => 'application/json' }, [JSON.generate(obj)]]
  end

  def issue_token(payload)
    payload = payload.merge({ 'iat' => Time.now.to_i })
    JWT.encode(payload, SECRET, 'HS256')
  end

  def verify_token(token)
    return nil unless token
    begin
      decoded = JWT.decode(token, SECRET, true, algorithm: 'HS256')
      decoded[0]
    rescue
      nil
    end
  end
end
