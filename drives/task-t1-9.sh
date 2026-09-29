#!/usr/bin/env zsh
# task-t1-9: the Mapo Glass theme in dark, light and reduced transparency, chosen by `config.toml [ui]`
# (PLAN T1.9, UX §2.3, §9). Each variant is a fixture in drives/fixtures/ and a fresh app launch against the
# same daemon. Without pixels the drive checks what snapshots can show: the resolved appearance and Reduce
# Transparency, the absent title bar, the traffic lights inside the rail, row heights, the pane insets and
# that no AX label changes between variants. The token table (board vs implemented) goes to tokens.md.
set -euo pipefail
source "${0:A:h}/lib.sh"

FIXTURES="${0:A:h}/fixtures"
DRIVE_CONFIG=${DRIVE_CONFIG:-$FIXTURES/ui-dark.toml}
drive_begin task-t1-9

DATA=$("$MAPO_BIN" --instance "$DRIVE_INSTANCE" instance show --json | jq -r .dataDir)
# What `reduce-transparency = "system"` should resolve to. The drive never changes the setting.
SYSTEM_RT=$([[ $(defaults read com.apple.universalaccess reduceTransparency 2>/dev/null || print 0) == 1 ]] && print true || print false)

# relaunch FIXTURE: quits the app, installs FIXTURE as config.toml, and starts the app again.
relaunch() {
    local app_pid=$DRIVE_APP_PID
    mapo ui key cmd+q >/dev/null || true
    for _ in {1..100}; do kill -0 $app_pid 2>/dev/null || break; sleep 0.05; done
    DRIVE_APP_PID=0
    cp "$1" "$DATA/config.toml"
    _drive_start_app_impl
    mapo ui wait 'pane.terminal:terminal-1' --timeout-ms 5000 >/dev/null
    mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null
}

# labels SNAPSHOT: every identified element as [id, role, label], sorted; frames and values left out.
labels() {
    jq -c '[.tree | .. | objects | select(.id? != null) | [.id, .role, (.label // "")]] | sort' "$1"
}

# check_variant NAME APPEARANCE REDUCE_TRANSPARENCY: the window and layout checks of one variant.
check_variant() {
    local name=$1 appearance=$2 rt=$3 win
    ui_snapshot "$name"; ui_shot "$name"
    win=$(mapo ui window)
    print -r -- "$win" > "$EVIDENCE/window-$DRIVE_STEP-$name.json"
    print -r -- "$win" | expect_json '[.appearance, .reduceTransparency]' "[\"$appearance\",$rt]"
    print -r -- "$win" | expect_json '.titleBarHidden' true
    # The traffic lights sit inside the rail: left of its divider and within the 52 pt toolbar band.
    local divider
    divider=$(jq '[.tree | .. | objects | select(.id? == "window.divider:rail") | .frame.x] | first' "$SNAP")
    print -r -- "$win" |
        expect_json "[.trafficLights.x > 0, (.trafficLights.x + .trafficLights.w) < $divider, (.trafficLights.y + .trafficLights.h) <= 52]" \
            '[true,true,true]'
    # S2 row heights: workspace 26, tab 24 (UX §3.1).
    jq -c '[.tree | .. | objects | select((.id // "") | test("^rail\\.(workspace|tab):")) | .frame.h] | unique' "$SNAP" |
        expect_json . '[24,26]'
    # Panes sit 10 from the rail and 4 below the toolbar band (UX §2.2).
    jq -c --argjson d "$divider" \
        '[.tree | .. | objects | select((.id // "") | startswith("pane:")) | .frame] | first | [(.x - $d | round), .y]' "$SNAP" |
        expect_json . '[10,56]'
    labels "$SNAP" > "$DRIVE_TMP/labels-$name.json"
    # The launch logs what it applied (Theme.apply).
    local logdir line
    logdir=$(mapo instance show | jq -r .logDir)
    line=$(cat "$logdir"/app.*.log(N) | grep ' appearance ' | tail -1 || true)
    print -r -- "${line#* appearance }" | jq -R 'split(" ")[0:2]' |
        expect_json . "[\"$appearance\",\"reduceTransparency=$rt\"]"
}

step "A workspace with a shell"
mapo ui key cmd+shift+n >/dev/null
mapo ui wait 'pane.terminal:terminal-1' --state focused --timeout-ms 3000 >/dev/null
mapo tab wait terminal-1 --until idle --timeout-ms 5000 >/dev/null

step "Dark (ui-dark.toml): dark, glass"
check_variant dark dark false

step "Light (ui-light.toml): light, Reduce Transparency from the system"
relaunch "$FIXTURES/ui-light.toml"
check_variant light light "$SYSTEM_RT"

step "Reduced transparency (ui-reduce-transparency.toml): dark, opaque glass"
relaunch "$FIXTURES/ui-reduce-transparency.toml"
check_variant reduce-transparency dark true

step "The AX labels are the same in every variant"
for v in light reduce-transparency; do
    diff -q "$DRIVE_TMP/labels-dark.json" "$DRIVE_TMP/labels-$v.json" >/dev/null && same=true || same=false
    print -r -- "$same" | expect_json . true
done
jq length "$DRIVE_TMP/labels-dark.json" | jq -e '. > 10' >/dev/null && print "   PASS $(jq length "$DRIVE_TMP/labels-dark.json") labels compared"

# The board-vs-implementation table. No pixels on this machine, so every visual claim is marked.
cat > "$EVIDENCE/tokens.md" <<'EOF'
# task-t1-9 tokens: design boards vs Theme

Board values are the CSS in docs/design/A-source-list.dc.html (window, panes, inspector) and
S2-rail-slimmer.dc.html (rail). The boards are dark only; light values come from UX §9.1 and have no board
to compare with. "Match" compares values in code. Rendering is **Not verified (no pixels)** for every row.

| Token | Board value | Implemented (dark) | Match |
|---|---|---|---|
| backdrop gradient | A: `linear-gradient(180deg, #25272E, #1F2127)` | `backdropTop` #25272E → `backdropBottom` #1F2127 | yes |
| backdrop glow, top left | A: `radial-gradient(1100px 640px at 8% -12%, rgba(125,166,255,0.13), transparent 62%)` | `backdropGlowTopLeading` #7DA6FF @ 0.13, ellipse 1100×640 at (8%, −12%), fades by 0.62 | yes (S2's crop uses 600×420 at 10% −10%, 0.14; A governs the window) |
| backdrop glow, bottom right | A: `radial-gradient(900px 620px at 104% 112%, rgba(172,140,255,0.09), transparent 60%)` | `backdropGlowBottomTrailing` #AC8CFF @ 0.09, 900×620 at (104%, 112%), fades by 0.60 | yes |
| glass | A, S2: `rgba(43,46,54,0.62)`, blur 28, saturate 160% | `glass` #2B2E36 @ 0.62; the rail and inspector use system glass from their split view items (UX §2.3) | token yes; material not compared |
| hairline | A, S2: `1px solid rgba(255,255,255,0.08)` | `hairline` white @ 0.08 | yes |
| highlight | A, S2: `inset 0 1px 0 rgba(255,255,255,0.06)` | `highlight` white @ 0.06 | yes |
| pane | A: `#1D1F25`, radius 12 | `pane` #1D1F25, `Radius.pane` 12 | yes |
| paneHairline | A: `1px solid rgba(255,255,255,0.07)` | `paneHairline` white @ 0.07 | yes |
| paneDivider | A: header `border-bottom: 1px solid rgba(255,255,255,0.06)` | `paneDivider` white @ 0.06 (header rule and exit bar now use it; they used paneHairline) | yes |
| focus ring and shadow | A: `0 0 0 1.5px accent, 0 10px 30px rgba(0,0,0,0.25)` | ring 1.5 `accent` outside the edge; shadow black 0.25, offset 10 down, radius 15 | yes |
| control | A: text button `rgba(255,255,255,0.07)` | `control` white @ 0.07 | yes (not yet used by the header's Stop button) |
| selection | S2: selected row `rgba(138,176,255,0.16)` | `selection` #8AB0FF @ 0.16 | yes |
| rowCurrent | A: tree current row `rgba(255,255,255,0.08)` | `rowCurrent` white @ 0.08 | yes |
| text.primary | A, S2: #F2F3F6 | #F2F3F6 | yes |
| text.body | A, S2: #D5D8DF | #D5D8DF | yes |
| text.secondary | A, S2: #9EA3AE | #9EA3AE | yes |
| text.secondaryOnSelection | A: segments #C3C7D0 | #C3C7D0 | yes |
| icon | A, S2: #A3A8B3 | #A3A8B3 | yes |
| icon.selected | S2: selected row icon #DCE3F2 | #DCE3F2 | yes |
| icon.focused | A: focused header icon #C3CBDB | `iconFocused` #C3CBDB | yes |
| lineNumber | A: gutter #858A98 | #858A98 | yes |
| accent | A: `accent` prop default #8AB0FF | #8AB0FF | yes |
| needs, needs.tint, needs.fill, on fill | S2: #E8B557, #F1CB86, badge #E8B557 with #1D1F25 text | same | yes |
| failed, failed.tint | S2: #F47067, #F6C9C5 | same | yes |
| running, done | S2: #6CA8FF, #6FCF97 | same | yes |
| syntax keyword, string, function, type, number | A: #C3A6FF, #A6D98C, #8AB0FF, #7FD1C7, #E8B557 | same | yes |
| diff.addedBg | A: editor changed-line tint `rgba(111,207,151,0.07)` | `diffAddedBg` @ 0.14 (UX §9.1, for the diff view) | differs by use; UX governs |
| terminal | A: bg #1D1F25, fg #D5D8DF, padding 12 14 | `TerminalTheme.dark` bg #1D1F25, fg #D5D8DF; ghostty padding x 14, y 12 | yes |
| rail row heights | S2: header 24 (6 + 11 + 6 ≈ 24), workspace 26, tab 24 | checked in snapshots: workspace 26, tab 24 | yes (checked) |
| title bar | A, S2: none; traffic lights inside the rail at 16, gap 8 | `titleBarHidden` true; traffic lights left of the rail divider, inside the 52 pt band | yes (checked); positions within the rail are AppKit's |

Not verified (no pixels): the rendered backdrop and glows, the rail and inspector glass matching each other,
the opaque fill under forced Reduce Transparency, light mode's look, and every color on screen.
EOF

drive_end
