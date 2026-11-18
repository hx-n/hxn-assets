import Models.Lore;

@:build(hxn.assets.Assets.build())
class GameAssets {
	@:asset("knowledge/ruin.json") @:contentAddressed
	public static var Ruin:Lore;
}
