package hxn.assets;

import haxe.Exception;
import haxe.io.Bytes;
import hxn.file.Storage;
import hxn.Future;
import hxn.Unit;
import hxn.assets.knowledge.KnowledgeBatch;
import hxn.assets.knowledge.KnowledgeQuery;
import hxn.assets.knowledge.KnowledgeSink;
import hxn.assets.native.GraphBackend;

/** Embedded KyuGraph access and a sink for annotated knowledge publication. */
@:buildXml('<target id="haxe" if="emscripten"><flag value="-sSTACK_SIZE=8388608" unless="hxn_assets_stack_size"/><flag value="-sSTACK_SIZE=${hxn_assets_stack_size}" if="hxn_assets_stack_size"/></target>')
class KnowledgeGraph implements KnowledgeSink {
	var backend:Null<GraphBackend>;
	var closing:Null<Future<Unit>>;

	/** True when the selected packaged engine includes JIT support. */
	public final jit:Bool;

	function new(backend:GraphBackend) {
		this.backend = backend;
		jit = backend.jitEnabled();
	}

	/** Opens an owned graph. An empty directory creates an in-memory graph. */
	public static function open(directory:String = ""):Future<KnowledgeGraph> {
		final backend = new GraphBackend();
		return backend.initialize(directory).map(_ -> new KnowledgeGraph(backend)).recover(error -> {
			backend.close();
			throw error;
		});
	}

	/** Restores a portable checkpoint; no native filesystem access is required. */
	public static function restore(bytes:Bytes):Future<KnowledgeGraph> {
		final backend = new GraphBackend();
		return backend.initializeSnapshot(bytes).map(_ -> new KnowledgeGraph(backend)).recover(error -> {
			backend.close();
			throw error;
		});
	}

	/** Loads a checkpoint from application-scoped storage, including browser IndexedDB. */
	public static function load(files:Storage, path:String):Future<KnowledgeGraph>
		return files.readSave(path).flatMap(restore);

	/** Captures one consistent graph state in a versioned, portable checkpoint. */
	public function snapshot():Future<Bytes> {
		if (backend == null)
			return Future.rejected(new Exception("knowledge graph is closed"));
		return backend.snapshot();
	}

	/** Saves a copied checkpoint; the application retains ownership of the storage. */
	public function save(files:Storage, path:String):Future<Unit>
		return snapshot().flatMap(bytes -> files.writeSave(path, bytes));

	public function apply(batch:KnowledgeBatch):Future<Unit> {
		if (backend == null)
			return Future.rejected(new Exception("knowledge graph is closed"));
		return backend.applyJson(batch.toJson());
	}

	/** Executes parameterized Cypher and decodes owned result values. */
	public function query(cypher:String, ?parameters:haxe.DynamicAccess<Dynamic>):Future<KnowledgeQuery> {
		if (backend == null)
			return Future.rejected(new Exception("knowledge graph is closed"));
		try {
			return backend.queryJson(cypher, KnowledgeQuery.encodeParameters(parameters == null ? {} : parameters)).map(KnowledgeQuery.decode);
		} catch (error:Exception) {
			return Future.rejected(error);
		}
	}

	/** Stops new operations and releases the graph after its native shutdown. */
	public function close():Future<Unit> {
		if (closing != null)
			return closing;
		final current = backend;
		backend = null;
		if (current == null)
			return Future.resolved(Unit.Nothing);
		closing = current.shutdown().map(_ -> {
			current.close();
			return Unit.Nothing;
		}).recover(error -> {
			current.close();
			throw error;
		});
		return closing;
	}
}
