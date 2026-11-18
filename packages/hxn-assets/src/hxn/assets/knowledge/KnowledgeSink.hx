package hxn.assets.knowledge;

import hxn.Future;
import hxn.Unit;

/**
 * Atomically applies one source revision. Preserve idempotency, schema checks,
 * replacement of outgoing links and tombstones across reconnect/restart.
 * Authentication, scheduling and transport belong to the configured application.
 */
interface KnowledgeSink {
	public function apply(batch:KnowledgeBatch):Future<Unit>;
}
