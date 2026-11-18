package hxn.assets;

/** A stable semantic ID whose target schema is checked by the knowledge macro. */
abstract KnowledgeRef<T>(String) from String to String {
	public inline function new(id:String)
		this = id;
}
