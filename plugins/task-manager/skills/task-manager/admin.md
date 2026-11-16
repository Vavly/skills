# Admin: the local dashboard of all runs

`SKILL.md` sends you to this file for `/task-manager admin`. The admin page is a local web server
in this plugin. It reads the run folders of the task manager, for every project on this machine.
The server file is `<skill>/../../admin/server.mjs`: `admin/server.mjs` in the plugin folder, two
levels above the folder of this file. If that file does not exist, the skill was copied by hand
with no plugin around it: tell the user to run `admin/server.mjs` from a clone of the plugin's
repository.

1. Start the server in the background, with the arguments that the user gave:
   `node <server file> --open [--port <n>] [--root <dir>]`.
   `--open` opens the page in the user's default browser.
   The default port is 4747. The default root is `$TASK_MANAGER_RUNS`, or `~/.task-manager/runs`.
2. Read its first lines of output. They give the URL and the root. Give both to the user.
   - "port … is in use; opened …": a server runs already, and its page is now open. Give the user
     that URL. Do not start a second server on another port unless the user asks.
   - "the root … does not exist": no run exists yet. Tell the user that the first run makes the
     folder.
3. To stop the server, run `node <server file> --stop [--port <n>]`. It stops only a task-manager
   admin server. Do this when the user's arguments start with `stop`
   (`/task-manager admin stop [--port <n>]`), and do not start a server then. Tell the user the
   one line that the command prints.

The page never writes a run file. Its three write actions run the ledger script of this plugin in
the project's checkout: "Mark as finished", an answer to a question, and the record of a merged
PR. The page cannot answer a session-only question, for example the merge yes. The server binds to
127.0.0.1 only.
