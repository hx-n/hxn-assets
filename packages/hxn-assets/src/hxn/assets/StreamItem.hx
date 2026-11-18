package hxn.assets;

/** A stream boundary separate from a nullable payload and an empty message. */
typedef StreamItem<T> = {var done:Bool; var value:Null<T>; var text:Bool;}
