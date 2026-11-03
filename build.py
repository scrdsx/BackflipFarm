"""Bundle src/*.lua into dist/BackflipFarm.lua (one pasteable/loadstring-able file)."""
from pathlib import Path

root = Path(__file__).parent
order = ["ui", "farm", "loading"]  # dependencies first; main runs last

out = ["local __mods, __cache = {}, {}",
       "local function __import(n)",
       "\tif __cache[n] == nil then __cache[n] = __mods[n]() end",
       "\treturn __cache[n]",
       "end", ""]
for name in order:
    body = (root / "src" / f"{name}.lua").read_text(encoding="utf8")
    out.append(f'__mods["{name}"] = function()\n{body}\nend\n')
out.append("-- main")
out.append((root / "src" / "main.lua").read_text(encoding="utf8"))

dist = root / "dist"
dist.mkdir(exist_ok=True)
(dist / "BackflipFarm.lua").write_text("\n".join(out), encoding="utf8")
print("built", dist / "BackflipFarm.lua")
