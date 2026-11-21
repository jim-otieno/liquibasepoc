package org.research.zdm;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** Bound from app.schema-mode (env APP_SCHEMA_MODE). */
@ConfigurationProperties(prefix = "app")
public record AppProperties(SchemaMode schemaMode) {
    public AppProperties {
        if (schemaMode == null) {
            schemaMode = SchemaMode.OLD_ONLY;
        }
    }
}
