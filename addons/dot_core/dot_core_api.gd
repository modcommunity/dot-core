extends RefCounted

## dot-core's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 2: DotTransportDual, DotDualPeer, DotUdpDemux (WebSocket + ENet in one server).
# 3: DotMeteredPeer (any MultiplayerPeer, counted per channel; what net_stat draws).
# 4: DotAddonApi.FLOOR_FILE, apply_floors, floor_audit, guarded, and parse's file_name
#    (a game asking less of an addon whose newer API it guards).
# 5: camera/: DotCameraProbe, DotCameraBoom, DotCameraFade (cameras that stay out of the
#    level and fade the people between them and what they look at).
# 6: DotCollisionAudit (visible level geometry nothing collides with; `dot_no_collision` opt-out).
# 7: DotTcpScreen, DotTransportDual.tls_hello_screen / TlsHelloScreen / is_loopback_bind,
#    DotDualPeer.screen (a TLS ClientHello at a plain WebSocket listener closed at once).
# 8: DotRenderWarmup (draws a scene's materials once, out of sight, so shaders compile under a cover).
# 9: DotContentIndex, DotContentEntry (what mounted packs provide, tagged by session: solo or online).
# 10: loading/: DotLoadGate, DotLoadingCover (the game is not ready to be seen yet: holds,
#     requirements, frozen nodes, a cover a host can claim).
# 11: DotParallel (a fork/join on the worker pool that returns inside the tick: pure tasks,
#     results in index order, a verify mode that runs them twice).
# 12: DotYaml (the YAML subset reader), DotRotationSpec (maps.yml / games.yml: rotations,
#     wildcards, layering, `commands:`), DotCommandNames (renames, aliases, collision skip).
# 13: DotAddonConfig (cfg/addons/<name>/*.yml: every file read in name order over defaults,
#     then environment, then command line).
# 14: DotHttpServer, DotHttpRequest, DotHttpResponse (net/: a small HTTP/1.1 server, desktop and server only).
const LEVEL := 14
const OLDEST := 1
