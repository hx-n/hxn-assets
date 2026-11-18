package hxn.assets;

import hxn.Future;

class StaticCatalog implements CatalogSource {
	final catalog:AssetCatalog;

	public function new(catalog:AssetCatalog) {
		this.catalog = catalog;
	}

	public function load():Future<AssetCatalog>
		return Future.resolved(catalog);
}
