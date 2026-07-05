# Nexus Foward - Backend

Lightweight Ruby Rack backend providing a WebSocket endpoint for multiplayer.

Run locally:

```bash
cd backend
bundle install
bundle exec rackup -o 0.0.0.0 -p 3000
```

WebSocket endpoint: `ws://localhost:3000/ws`

Auth endpoints (JSON):

- `POST /register` { "username": "alice", "password": "secret" } -> 201 { "username": "alice", "token": "..." }
- `POST /login` { "username": "alice", "password": "secret" } -> 200 { "username": "alice", "token": "..." }

Use the returned `token` when opening the WebSocket: `ws://localhost:3000/ws?token=...`

Example curl:

```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"bob","password":"pw"}' http://localhost:3000/register
```

The backend stores users in `backend/db.sqlite3` (created automatically). To reset users, delete that file.# Nexus Foward - Frontend

Run locally:

```bash
cd frontend
npm install
npm run dev
```

The dev server runs on `http://localhost:5173` by default and connects to the backend WebSocket at `ws://localhost:3000/ws`.

Authentication:

1. Register: `POST /register` with JSON `{ "username": "alice", "password": "pw" }` -> returns `{ "username": "alice", "token": "..." }`
2. Login: `POST /login` same payload -> returns token
3. The frontend will attach the `token` as a query param when opening the WebSocket: `ws://localhost:3000/ws?token=...`

# Nexus Foward

Minimal scaffold for a multiplayer game platform.

Architecture
- Backend: Ruby (Rack) WebSocket server using `faye-websocket`, `sequel`, and `sqlite3`.
- Frontend: Vue 3 app bootstrapped with Vite.

Quick start

Backend
```bash
cd backend
bundle install
bundle exec rackup -o 0.0.0.0 -p 3000
```

Frontend
```bash
cd frontend
npm install
npm run dev
```

Endpoints and notes
- WebSocket endpoint: `ws://localhost:3000/ws?token=...&game_id=...`
- Auth: `POST /register` and `POST /login` (returns JWT token)
- Games: `POST /games`, `POST /games/:id/join`, `GET /games`, `POST /matchmake`
- Game state: `POST /games/:id/state` (authorized by token in body)
- Leaderboards: `POST /score`, `GET /leaderboard`, `GET /leaderboard/game/:id`
- Database: `backend/db.sqlite3` (created automatically). To reset, delete this file.

Configuration
- Set `NEXUS_SECRET` env var to change the JWT secret in production.

Next steps
- Persist richer game state, enforce turn order, add tests and CI, and harden auth.

Files
- Backend: [backend/app.rb](backend/app.rb), [backend/Gemfile](backend/Gemfile), [backend/config.ru](backend/config.ru)
- Frontend: [frontend/src/App.vue](frontend/src/App.vue), [frontend/src/main.js](frontend/src/main.js), [frontend/package.json](frontend/package.json)



