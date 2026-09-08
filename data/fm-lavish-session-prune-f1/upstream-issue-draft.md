### Title

`Bound live-session listeners and release SSE/watchers on end`

### Body

Lavish 0.1.63 uses one process-global EventEmitter and installs callbacks per live connection.
Each `/api/poll` request adds `feedback` and `ended` listeners.
Each `/events/:key` SSE connection adds `reload`, `agent-reply`, `agent-presence`, `layout-warnings`, and `ended` listeners.
The handlers filter by key after every global emit, so event cost is linear in all live connections and Node warns when the eleventh connection/listener arrives.

Disconnect cleanup is present and works, so the warning alone should not be called a historical-session leak.
The end path is incomplete, though.
`POST /api/end` marks the session ended and emits `ended`, but it neither removes/closes the session's chokidar watcher nor terminates matching SSE responses.
The browser receives `ended` and disables its UI, but its `EventSource` remains open.
Those callbacks and the watcher survive until the tab disconnects or the whole server shuts down.

#### Reproduction

1. Start an isolated Lavish 0.1.63 server with isolated state.
2. Create and open eleven small HTML artifacts.
3. Hold one agent poll open for each artifact.
4. Observe `MaxListenersExceededWarning` for `feedback` and `ended` when listener eleven is registered.
5. Attach eleven SSE clients to the corresponding `/events/:key` routes.
6. Observe warnings for `reload`, `agent-reply`, `agent-presence`, `layout-warnings`, and `ended`.
7. End one session with `lavish-axi end <existing-file>` while leaving its SSE client connected.
8. Observe the final `ended` event, then observe that the stream remains connected and a watcher for that key remains in the server map.
9. Emit an event for one key and observe every listener execute its key filter although only one client consumes the event.

#### Expected

Listener count should be bounded independently of the number of live review sessions.
Ending a session should send one final ended event, close/remove its SSE subscribers, and close/remove its file watcher.
Browser clients should close or unsubscribe from their EventSource when they enter ended state.

#### Suggested implementation

Replace per-connection global EventEmitter subscriptions with keyed subscriber maps, such as `Map<sessionKey, Set<pollWaiter>>` and `Map<sessionKey, Set<sseResponse>>`, and dispatch directly to the changed key.
Alternatively keep one shared listener per event and route through keyed maps, but do not add one emitter listener per response.
On end, deliver the final event, terminate and remove the matching SSE responses, close and delete the matching watcher, and clear any keyed waiters after their terminal response.
Have the browser call `EventSource.close()` on end; if the local SharedWorker solution is adopted, unsubscribe the key and close the origin stream when its subscriber set reaches zero.
Add tests asserting bounded emitter/listener counts with at least 50 live sessions and asserting watcher/SSE cleanup after end.
Do not solve this by raising or disabling `setMaxListeners`, because that preserves global O(N) fan-out and hides missing end cleanup.

### Existing related work

The closed upstream issue https://github.com/kunchenguid/lavish-axi/issues/171 added the ended event and read-only browser UI, but its fix stops short of closing the stream or watcher.
An all-issue keyword scan found no existing listener-bounding, bulk-end, archive, or prune issue; open issue https://github.com/kunchenguid/lavish-axi/issues/308 concerns a read-only session list.

The local-only commit `c9f08d3cb10c68435e10d000673bc167db849bb3` already prototypes browser connection sharing with a SharedWorker.
Its retained E2E report at `data/lavish-chrome-connlimit-c1/findings.md:28-48` shows eleven tabs loading with only two Chrome sockets and working live updates.
That commit is based on older local main, is not installed, and does not by itself fix agent-poll fan-out or watcher/SSE cleanup on end.
It is useful salvage material, not current proof that upstream is fixed.
