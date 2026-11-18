import hxn.assets.KnowledgeRef;

@:knowledge("Lore")
typedef Lore = {
	@:identity var id:String;
	@:fact var title:String;
	@:fact var text:String;
}

@:knowledge("World")
typedef World = {
	@:identity var id:String;
	@:fact var name:String;
}

@:knowledge("Npc")
typedef Npc = {
	@:identity var id:String;
	@:fact var name:String;
	@:fact var goal:String;
	@:fact var memories:Array<String>;
	@:relation("KNOWS") var knowledge:Array<KnowledgeRef<Lore>>;
	@:relation("IN_WORLD") var world:KnowledgeRef<World>;
	@:spatial("world", "metre") var position:{x:Float, y:Float, z:Float};
	var privatePrompt:String;
}

@:knowledge("QuestProgress")
typedef QuestProgress = {
	@:identity var id:String;
	@:fact var player:String;
	@:fact var state:String;
	@:relation("ABOUT") var lore:KnowledgeRef<Lore>;
}
