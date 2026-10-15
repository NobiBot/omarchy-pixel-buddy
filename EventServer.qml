import QtQuick
import Quickshell
import Quickshell.Io

// Hook event entry point: bin/pixel-buddy-hook writes one line of JSON into this Unix socket through socat.
// Event contents go only through the pipe and the socket; process arguments hold only the socket path.
//
// Two workarounds for Quickshell's SocketServer (quickshell-git 0.3.0):
// - If the peer disconnects first, a PeerClosedError warning is logged: this side disconnects after reading a line, and the hook's socat uses shut-none so it doesn't half-close;
// - Closed connection objects are only freed when listening stops (about 2 KB each): after a batch builds up and no connection is still open, listening restarts once.
Scope {
  id: events

  // Create the parent directory (0700) before calling start()
  property string path: ""
  signal received(string line)

  readonly property int recycleAfter: 500
  property int accepted: 0
  property int open: 0

  function start() {
    server.active = true
  }

  function recycle() {
    if (accepted < recycleAfter || open > 0) return
    accepted = 0
    server.active = false
    server.active = true
  }

  SocketServer {
    id: server
    path: events.path

    handler: Socket {
      id: conn

      onConnectionStateChanged: {
        if (connected) {
          events.open++
          events.accepted++
        } else {
          events.open--
          Qt.callLater(events.recycle)
        }
      }

      parser: SplitParser {
        onRead: line => {
          events.received(line)
          // Each connection sends one line; disconnect once the current read is handled
          Qt.callLater(() => {
            if (conn) conn.connected = false
          })
        }
      }
    }
  }
}
