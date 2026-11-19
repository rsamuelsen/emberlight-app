Shared map libraries, used by the guild map (UI/Map.lua) so its flames show on the world map and
minimap however another addon has changed them (OpenMap, ElvUI, SexyMap, square minimaps and so
on). Many map addons already carry the same libraries; LibStub loads only the newest copy, so they
share one. Copied unchanged; do not edit them here, replace them with a newer release instead.

- LibStub (public domain): from Ace3, https://github.com/WoWUIDev/Ace3,
  commit ac3d1225037e0dc74e025a72342c0f7824aae147.
- CallbackHandler-1.0 (BSD, LICENSE.txt in its folder): from the same Ace3 commit.
- HereBeDragons-2.0 and HereBeDragons-Pins-2.0 (BSD, by Nevcairiel):
  https://github.com/Nevcairiel/HereBeDragons, commit 90a7b2d8c065010dfb866e2b6bd56f5bc930029b.
  Its own list of game versions includes Forever (16001) and Retail (120100, 120105).
