<template>
  <div style="font-family: Arial, Helvetica, sans-serif; padding: 1rem;">
    <h1>Nexus Foward — Lobby</h1>

    <div v-if="!username" style="margin-bottom:1rem;">
      <h3>Login / Register</h3>
      <input v-model="form.username" placeholder="username" />
      <input v-model="form.password" type="password" placeholder="password" />
      <button @click="doLogin">Login</button>
      <button @click="doRegister">Register</button>
      <div style="color: red;" v-if="error">{{ error }}</div>
    </div>

    <div v-else style="margin-bottom: 1rem;">
      <div>Signed in as <strong>{{ username }}</strong></div>
      <div style="margin-top:0.5rem; margin-bottom:0.5rem;">
        <input v-model="gameForm.gameId" placeholder="game id to join" />
        <button @click="joinGame">Join</button>
        <button @click="createGame">Create</button>
      </div>

      <div v-if="currentGameId">In game <strong>{{ currentGameId }}</strong> — players: {{ players.join(', ') }}</div>

      <input v-model="message" @keyup.enter="sendMessage" placeholder="Type message and press Enter" />
      <button @click="sendMessage">Send</button>
    </div>

    <ul>
      <li v-for="(m, i) in messages" :key="i">
        <span v-if="m.type === 'system'">[SYSTEM]</span>
        <span v-else-if="m.type === 'state'">[STATE]</span>
        <span v-else-if="m.type === 'move'">[MOVE]</span>
        <strong v-if="m.from"> {{ m.from }}: </strong>
        <span>{{ formatData(m.data) }}</span>
      </li>
    </ul>
  
    <div style="margin-top:2rem;">
      <h3>Lobby</h3>
      <button @click="refreshGames">Refresh</button>
      <button @click="quickMatch">Quick Match</button>
      <ul>
        <li v-for="g in games" :key="g.id">
          [{{ g.id }}] {{ g.name }} — {{ g.players }}/{{ g.capacity }}
          <button @click="gameForm.gameId = g.id; joinGame()">Join</button>
        </li>
      </ul>
    </div>
  
    <div style="margin-top:2rem;">
      <h3>Leaderboards</h3>
      <button @click="refreshLeaderboard">Refresh</button>
      <div v-if="leaderboard.length === 0">No scores yet.</div>
      <ol>
        <li v-for="(r, i) in leaderboard" :key="i">{{ r.username }} — {{ r.score }} <span v-if="r.game_id">(game {{ r.game_id }})</span></li>
      </ol>
      <div v-if="username">
        <input v-model.number="submitScoreValue" placeholder="score" />
        <button @click="submitScore">Submit Score</button>
      </div>
    </div>
  </div>
</template>

<script setup>

import { ref, onMounted, onBeforeUnmount, watch } from 'vue'

const messages = ref([])
const message = ref('')
const form = ref({ username: '', password: '' })
let ws = null
const username = ref(localStorage.getItem('nexus_username') || null)
const token = ref(localStorage.getItem('nexus_token') || null)
const error = ref(null)
const currentGameId = ref(null)
const gameForm = ref({ gameId: '' })
const players = ref([])
const games = ref([])
const messageType = ref('chat')
const state = ref(null)
const leaderboard = ref([])
const submitScoreValue = ref(0)

watch(token, (t) => {
  if (t) {
    localStorage.setItem('nexus_token', t)
  } else {
    localStorage.removeItem('nexus_token')
  }
})

watch(username, (u) => {
  if (u) localStorage.setItem('nexus_username', u)
  else localStorage.removeItem('nexus_username')
})


function connectSocket(gameId = null) {
  if (!token.value) return
  try {
    const url = new URL('ws://localhost:3000/ws')
    url.searchParams.set('token', token.value)
    if (gameId) url.searchParams.set('game_id', gameId)
    ws = new WebSocket(url.toString())
  } catch (e) {
    error.value = 'WebSocket error'
    return
  }

  ws.addEventListener('message', (e) => {
    try {
      const d = JSON.parse(e.data)
      messages.value.push(d)

      // react to system/state messages for current game
      if (d.type === 'system' && d.game_id && currentGameId.value && d.game_id.toString() === currentGameId.value.toString()) {
        fetchGame(currentGameId.value)
      }
      if (d.type === 'state' && d.game_id && currentGameId.value && d.game_id.toString() === currentGameId.value.toString()) {
        state.value = d.data
      }
    } catch {
      messages.value.push({ data: e.data })
    }
  })

  ws.addEventListener('close', () => {
    // clear ws to allow reconnection
    ws = null
  })
}

onMounted(() => {
  if (token.value) connectSocket()
  refreshGames()
})

onBeforeUnmount(() => {
  if (ws) ws.close()
})

async function doRegister() {
  error.value = null
  const res = await fetch('http://localhost:3000/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: form.value.username, password: form.value.password })
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) { error.value = data.error || 'register failed'; return }
  token.value = data.token
  username.value = data.username
  connectSocket(currentGameId.value)
}

async function doLogin() {
  error.value = null
  const res = await fetch('http://localhost:3000/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: form.value.username, password: form.value.password })
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) { error.value = data.error || 'login failed'; return }
  token.value = data.token
  username.value = data.username
  connectSocket(currentGameId.value)
}

function sendMessage() {
  if (ws && ws.readyState === WebSocket.OPEN && message.value.trim() !== '') {
    let payloadData = message.value
    if (messageType.value === 'move') {
      try { payloadData = JSON.parse(message.value) } catch { payloadData = message.value }
    }
    ws.send(JSON.stringify({ type: messageType.value, data: payloadData }))
    message.value = ''
  }
}

function formatData(d) {
  try { return typeof d === 'string' ? d : JSON.stringify(d) } catch { return String(d) }
}

async function refreshGames() {
  const res = await fetch('http://localhost:3000/games')
  const data = await res.json().catch(() => ({}))
  games.value = data.games || []
}

async function quickMatch() {
  error.value = null
  const res = await fetch('http://localhost:3000/matchmake', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token.value })
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) { error.value = data.error || 'matchmake failed'; return }
  currentGameId.value = data.game_id
  players.value = data.players || []
  connectSocket(currentGameId.value)
}

async function fetchGame(id) {
  const res = await fetch(`http://localhost:3000/games/${encodeURIComponent(id)}`)
  const data = await res.json().catch(() => ({}))
  if (!res.ok) return
  players.value = data.players || []
  state.value = data.game && data.game.state
}

async function refreshLeaderboard() {
  const res = await fetch('http://localhost:3000/leaderboard')
  const data = await res.json().catch(() => ({}))
  leaderboard.value = data.leaderboard || []
}

async function submitScore() {
  if (!username.value) { error.value = 'login first'; return }
  const res = await fetch('http://localhost:3000/score', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: token.value, score: submitScoreValue.value, game_id: currentGameId.value })
  })
  if (res.ok) { submitScoreValue.value = 0; refreshLeaderboard() }
}

async function createGame() {
  error.value = null
  const res = await fetch('http://localhost:3000/games', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({})
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) { error.value = data.error || 'create failed'; return }
  currentGameId.value = data.game_id
  players.value = []
  connectSocket(currentGameId.value)
}

async function joinGame() {
  error.value = null
  const id = gameForm.value.gameId
  if (!id) { error.value = 'enter game id'; return }
  const res = await fetch(`http://localhost:3000/games/${encodeURIComponent(id)}/join`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token.value })
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) { error.value = data.error || 'join failed'; return }
  currentGameId.value = data.game_id
  players.value = data.players || []
  connectSocket(currentGameId.value)
}
</script>
