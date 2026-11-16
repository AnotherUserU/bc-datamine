# bc-datamine

Read-only data dump for Build and Conquer (internal executor). Writes one file, bcdump_all.txt, to /storage/emulated/0/Download (or the executor workspace if blocked).

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/AnotherUserU/bc-datamine/main/datamine.lua"))()
```

Combat logger (listens to combat RemoteEvents during a war to measure intercept rates; writes bc_combatlog.txt):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/AnotherUserU/bc-datamine/main/combatlog.lua"))()
```
