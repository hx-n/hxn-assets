package hxn.assets;

import hxn.Future;

/** Produces an immutable catalog snapshot without selecting a hosting provider. */
interface CatalogSource {
	public function load():Future<AssetCatalog>;
}
