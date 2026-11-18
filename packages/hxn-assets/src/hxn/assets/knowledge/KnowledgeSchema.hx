package hxn.assets.knowledge;

/** The selected semantic fields of one annotated Haxe type. */
typedef KnowledgeSchema = {
	var name:String;
	var version:Int;
	var identity:String;
	var facts:Array<KnowledgeFact>;
	var relations:Array<KnowledgeRelation>;
	var spatial:Null<KnowledgeSpatialSelection>;
}

/** A scalar or homogeneous scalar-array property. */
typedef KnowledgeFact = {
	var name:String;
	var kind:String;
	var nullable:Bool;
}

/** A named, typed outgoing relationship selected from a declaration field. */
typedef KnowledgeRelation = {
	var name:String;
	var target:String;
	var many:Bool;
	var nullable:Bool;
}

/** The relationship supplying the coordinate space and its declared unit system. */
typedef KnowledgeSpatialSelection = {
	var relation:String;
	var units:String;
}
