import QtQuick
import Quickshell
import Quickshell.Io
import "lib/i18n.mjs" as I18n

// Runs claude -p / codex exec headless to generate one line of text. Only one request runs at a time.
// PIXEL_BUDDY_INTERNAL=1: pixel-buddy-hook exits right away when it sees this, so the buddy's own calls don't feed back in as work status events.
// Prompts and chat history never go in command-line arguments (process arguments are visible to every user on this machine):
// the prompt goes through stdin, and Claude's system prompt is written to a file under stateDir (0700) whose path is passed with --system-prompt-file.
Scope {
  id: llm

  // Tells the system prompt files of several instances apart
  property string name: "llm"
  property string home: ""
  property string stateDir: ""
  readonly property bool busy: proc.running
  property string lastUserText: ""
  // Caller's own tag (step summaries use it to remember which session it was for)
  property string tag: ""

  property string buddyId: ""
  property string kind: ""
  property string meme: ""
  property bool timedOut: false

  // When failed = true, text is the failure reason shown to the user
  signal finished(string buddyId, string kind, string text, string meme, bool failed)

  // cheap = automatic task: Codex also lowers its reasoning effort
  function run(provider, model, systemPrompt, prompt, buddyId, kind, meme, cheap) {
    if (proc.running) return false
    var cmd
    if (provider === "codex") {
      // Only text is needed, so like claude it gets no tools. -s read-only only restricts shell commands, not connectors, plugins or web search,
      // and connectors tied to the ChatGPT account (Gmail, Drive, GitHub etc.) aren't in config.toml and --ignore-user-config can't remove them,
      // so each is turned off. The remaining apply_patch (built into some models) is kept from writing by read-only + approval_policy=never.
      // Feature names match `codex features list` in codex-cli 0.147; an unknown name makes codex exit with an error.
      // Without a PROMPT argument, codex exec reads its instructions from stdin
      cmd = ["codex", "exec",
        "--ignore-user-config", "--ignore-rules",
        "--skip-git-repo-check", "--ephemeral",
        "-s", "read-only", "-c", "approval_policy=\"never\"",
        "--disable", "unified_exec", "--disable", "shell_tool",
        "--disable", "apps", "--disable", "plugins", "--disable", "tool_suggest",
        "--disable", "multi_agent", "--disable", "view_image",
        "--disable", "browser_use", "--disable", "computer_use", "--disable", "image_generation",
        "--disable", "hooks",
        "-c", "web_search=\"disabled\"",
        "--color", "never"]
      if (model) cmd.push("-m", model)
      if (cheap) cmd.push("-c", "model_reasoning_effort=\"low\"")
      proc.input = systemPrompt + "\n\n" + prompt
    } else {
      systemFile.setText(systemPrompt)
      // Without a prompt argument, claude -p reads from stdin
      proc.input = prompt
      cmd = ["claude", "-p",
        "--system-prompt-file", systemFile.path,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "text"]
      if (model) cmd.push("--model", model)
    }
    llm.buddyId = buddyId
    llm.kind = kind
    llm.meme = meme || ""
    llm.timedOut = false
    proc.command = cmd
    proc.stdinEnabled = true
    proc.running = true
    timeout.restart()
    return true
  }

  // Chat asks the model to reply with {"text","meme"}; if it doesn't comply, the whole reply is treated as text
  function parseReply(raw) {
    var text = String(raw || "").trim()
    var m = text.match(/\{[\s\S]*\}/)
    if (m) {
      try {
        var obj = JSON.parse(m[0])
        if (obj && typeof obj.text === "string") return { text: obj.text.trim(), meme: String(obj.meme || "") }
      } catch (e) {}
    }
    return { text: text.replace(/^["“]|["”]$/g, ""), meme: "" }
  }

  FileView {
    id: systemFile
    path: llm.stateDir + "/" + llm.name + "-system-prompt.txt"
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: proc
    property string input: ""
    workingDirectory: llm.stateDir
    // Close stdin right after writing; the CLI only starts once it reads EOF
    onStarted: {
      proc.write(proc.input)
      proc.stdinEnabled = false
      proc.input = ""
    }
    environment: ({ PIXEL_BUDDY_INTERNAL: "1", AGENT_PET_INTERNAL: "1" })
    stdout: StdioCollector { id: out }
    stderr: StdioCollector { id: err }

    onExited: function(exitCode) {
      timeout.stop()
      if (llm.timedOut) {
        llm.finished(llm.buddyId, llm.kind, I18n.t("llmTimeout"), "", true)
        return
      }
      if (exitCode !== 0) {
        var reason = String(err.text || out.text || "").trim().split("\n").pop()
        llm.finished(llm.buddyId, llm.kind, I18n.t("llmFailed", { reason: reason || I18n.t("llmExitCode", { code: exitCode }) }), "", true)
        return
      }
      var reply = llm.parseReply(out.text)
      if (!reply.text) {
        llm.finished(llm.buddyId, llm.kind, I18n.t("llmEmpty"), "", true)
        return
      }
      llm.finished(llm.buddyId, llm.kind, reply.text, llm.kind === "whisper" ? llm.meme : reply.meme, false)
    }
  }

  Timer {
    id: timeout
    interval: 90000
    onTriggered: {
      llm.timedOut = true
      proc.signal(15)
    }
  }
}
