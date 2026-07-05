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

The backend stores users in `backend/db.sqlite3` (created automatically). To reset users, delete that file.


