class_name MPHarness
extends RefCounted
## Builds the multiplayer runtime under a host node: the client, and the layer that presents what
## the client receives.
##
## Lives outside GameRoot for two reasons. The first is the 900-line ceiling, which GameRoot has
## been within a few lines of for several slices. The second is the ordering bug this file makes
## impossible: `add_to_group("multiplayer")` is what tells CreationSystem to route placements
## through the server, so joining the group has to happen *after* the client is configured and
## wired to its presenter. Doing that in one place means the game boot path and the probe path
## cannot drift apart.


static func attach(host: Node, token: String, url: String, port: int) -> MultiplayerClient:
	var mp := MultiplayerClient.new()
	mp.name = "MultiplayerClient"
	mp.configure(token, url, port)
	host.add_child(mp)
	# Parented to the client rather than to the world: the layer is meaningless without the state
	# it presents, and `mp/RemoteAvatarLayer` is one stable path instead of two nodes that can be
	# attached in the wrong order.
	var layer := RemoteAvatarLayer.new()
	layer.name = "RemoteAvatarLayer"
	mp.add_child(layer)
	layer.bind(mp)
	mp.add_to_group("multiplayer")
	return mp


static func layer_of(mp: MultiplayerClient) -> RemoteAvatarLayer:
	return mp.get_node("RemoteAvatarLayer") as RemoteAvatarLayer


## A second client used only to prove replication: it logs in as its own account, sends no
## automatic input (the probe drives its position explicitly), presents nothing, and deliberately
## does not join the "multiplayer" group — that group is how CreationSystem decides which client
## owns the local world, and a synthetic peer answering it would route placements to the wrong one.
static func attach_silent(host: Node, token: String, url: String, port: int) -> MultiplayerClient:
	var mp := MultiplayerClient.new()
	mp.name = "PeerClient"
	mp.auto_input = false
	mp.configure(token, url, port)
	host.add_child(mp)
	return mp
