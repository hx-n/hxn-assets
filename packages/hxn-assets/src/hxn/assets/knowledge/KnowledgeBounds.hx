package hxn.assets.knowledge;

/** World-coordinate AABB; point declarations have equal minimum and maximum. */
typedef KnowledgeBounds = {
	var world:String;
	var units:String;
	var minX:Float;
	var minY:Float;
	var minZ:Float;
	var maxX:Float;
	var maxY:Float;
	var maxZ:Float;
}
