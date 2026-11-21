package org.research.zdm;

/** API view of a customer. The storage column behind "name" depends on the schema mode. */
public record Customer(Long id, String name, String email) {
}
