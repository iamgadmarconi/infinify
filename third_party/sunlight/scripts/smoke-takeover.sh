#!/bin/zsh
# Smoke test for takeover mode. Start Sunlight first (`CANVAS_TAKEOVER=light make run` is enough), stay at
# the keyboard, then run this. It drives TextEdit through a launch kept on the canvas, absorb, the Cmd-Tab
# switcher, minimize, Hide Others, Cmd-H, relaunch, Return and quit, printing the frontmost app after
# each step; the expected app is in each heading. Watch Sunlight's terminal for the matching log lines.
front() { osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>&1 | head -1; }
key() { if [ -n "$2" ]; then osascript -e "tell application \"System Events\" to key code $1 using $2"; else osascript -e "tell application \"System Events\" to key code $1"; fi; }
pgrep -f "Sunlight.app/Contents/MacOS/Sunlight" >/dev/null && echo "Sunlight up" || { echo "Sunlight is not running"; exit 1; }
echo "front at start: $(front)"
echo "== a. TextEdit document + activate at once (a launch: the window isn't on the canvas yet) -> expect Sunlight; log: Launch: … opens on the canvas, … is on the canvas"
osascript -e 'tell application "TextEdit" to make new document' >/dev/null; sleep 0.2; osascript -e 'tell application "TextEdit" to activate'; sleep 3; echo "front: $(front)"
echo "== b. activate again, its window on the canvas now (absorb) -> expect TextEdit"
osascript -e 'tell application "TextEdit" to activate'; sleep 2; echo "front: $(front)"
echo "== c. Cmd-Tab -> expect Sunlight"; key 48 "command down"; sleep 1.5; echo "front: $(front)"
echo "== d. Cmd-Tab -> expect TextEdit"; key 48 "command down"; sleep 2; echo "front: $(front)"
echo "== e. second document (sibling absorb) -> expect TextEdit"; osascript -e 'tell application "TextEdit" to make new document' >/dev/null; sleep 1.5; echo "front: $(front)"
echo "== f. minimize the entered window -> expect Sunlight, minimized false"; osascript -e 'tell application "TextEdit" to set miniaturized of window 1 to true'; sleep 2; echo "front: $(front)  minimized: $(osascript -e 'tell application "TextEdit" to miniaturized of window 1' 2>&1)"
echo "== g. Cmd-Tab -> expect TextEdit"; key 48 "command down"; sleep 2; echo "front: $(front)"
echo "== h. Hide Others from TextEdit -> expect TextEdit, Sunlight visible true"; osascript -e 'tell application "System Events" to keystroke "h" using {command down, option down}'; sleep 1.5; echo "front: $(front)  Sunlight visible: $(osascript -e 'tell application "System Events" to visible of process "Sunlight"' 2>&1)"
echo "== i. Cmd-H hides TextEdit -> expect Sunlight"; osascript -e 'tell application "System Events" to keystroke "h" using command down'; sleep 1.5; echo "front: $(front)"
echo "== j. open -a TextEdit (its windows left the canvas when hidden: a launch) -> expect Sunlight"; open -a TextEdit; sleep 3; echo "front: $(front)"
echo "== k. Return over the top window (enter it) -> expect TextEdit"; key 36 ""; sleep 2; echo "front: $(front)"
echo "== l. quit TextEdit -> expect Sunlight"; osascript -e 'tell application "TextEdit" to quit saving no'; sleep 2; echo "front: $(front)"
