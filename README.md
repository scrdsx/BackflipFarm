# Scrdsx Solutions - Backflip Farm

Black-themed UI + backflip autofarm for game 122840796290491 (own game).

```
loader.lua        the loadstring target; fetches every file in src/ and runs them
src/ui.lua        UI library (sidebar tabs, animated search, toggle/slider/button/label, toasts)
src/farm.lua      farm logic (launch + spin, TrickState feedback, auto-raise jump power)
src/loading.lua   loading screen
src/main.lua      builds the window and wires keys
dist/             optional single-file bundle (python build.py)
tools/            trick_probe.lua (remote/currency probe; F8 copies report)
```

## Loadstring

Host this folder anywhere that serves raw files (GitHub raw, your own server), then:

```lua
getgenv().ScrdsxBase = "https://YOUR-HOST/path/"  -- folder that contains loader.lua and src/
loadstring(game:HttpGet(ScrdsxBase .. "loader.lua"))()
```

### Test locally, no hosting
```
cd Desktop\BackflipFarm
python -m http.server 8000
```
```lua
loadstring(game:HttpGet("http://localhost:8000/loader.lua"))()
```
(default base is `http://localhost:8000/`, so the line above is enough)

### Or from the executor workspace
Copy this folder into the executor's `workspace`, then:
```lua
getgenv().ScrdsxLocal = "BackflipFarm/"
loadstring(readfile("BackflipFarm/loader.lua"))()
```

Keys: RightShift hide/show, F6 toggle farm, `/` focus search.
Untested in game: written from the clipboard dump only.
