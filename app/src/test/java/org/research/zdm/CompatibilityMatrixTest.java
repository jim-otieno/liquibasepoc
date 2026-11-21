package org.research.zdm;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import liquibase.Contexts;
import liquibase.LabelExpression;
import liquibase.Liquibase;
import liquibase.database.Database;
import liquibase.database.DatabaseFactory;
import liquibase.database.jvm.JdbcConnection;
import liquibase.resource.DirectoryResourceAccessor;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Compatibility invariant, tested mechanically: after each phase, the schema
 * state must serve both application modes adjacent to that phase.
 * Phases are applied in order to one database, exactly as the pipeline does.
 */
@Testcontainers
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class CompatibilityMatrixTest {

    @Container
    static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");

    /** Changelogs live in ../db relative to the Maven module. */
    private static final Path DB_DIR = Path.of("..", "db").toAbsolutePath().normalize();

    private static void applyPhase(String label) throws Exception {
        try (Connection c = DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())) {
            Database db = DatabaseFactory.getInstance().findCorrectDatabaseImplementation(new JdbcConnection(c));
            try (Liquibase lb = new Liquibase("changelog/db.changelog-master.yaml",
                    new DirectoryResourceAccessor(DB_DIR), db)) {
                lb.update(new Contexts(), new LabelExpression(label));
            }
        }
    }

    private static JdbcTemplate jdbc() {
        return new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
    }

    private static CustomerRepository repo(SchemaMode mode) {
        return new CustomerRepository(jdbc(), new AppProperties(mode), new SimpleMeterRegistry());
    }

    /** Create, read back and rename one customer through the given mode. */
    private static void exercise(SchemaMode mode) {
        CustomerRepository r = repo(mode);
        Customer c = r.create("Ada " + mode, mode.name().toLowerCase() + "@example.org");
        assertThat(r.find(c.id())).get().extracting(Customer::name).isEqualTo("Ada " + mode);
        assertThat(r.rename(c.id(), "Grace " + mode)).isTrue();
        assertThat(r.find(c.id())).get().extracting(Customer::name).isEqualTo("Grace " + mode);
    }

    @Test
    @Order(1)
    void baseline_serves_v1() throws Exception {
        applyPhase("baseline");
        exercise(SchemaMode.OLD_ONLY);
    }

    @Test
    @Order(2)
    void expand_serves_v1_and_v2() throws Exception {
        applyPhase("expand");
        exercise(SchemaMode.OLD_ONLY);
        exercise(SchemaMode.DUAL_WRITE_READ_OLD);
    }

    @Test
    @Order(3)
    void migrate_serves_v2_and_v3() throws Exception {
        // External backfill job (experiments/backfill.py does this in batches).
        jdbc().update("UPDATE customer SET full_name = customer_name WHERE full_name IS NULL");
        applyPhase("migrate");
        exercise(SchemaMode.DUAL_WRITE_READ_OLD);
        exercise(SchemaMode.DUAL_WRITE_READ_NEW);
    }

    @Test
    @Order(4)
    void harden_serves_v2_v3_v4_and_rejects_v1() throws Exception {
        applyPhase("harden");
        exercise(SchemaMode.DUAL_WRITE_READ_OLD);
        exercise(SchemaMode.DUAL_WRITE_READ_NEW);
        exercise(SchemaMode.NEW_ONLY);
        // v1 would leave full_name NULL: the validated CHECK constraint must refuse it.
        assertThatThrownBy(() -> repo(SchemaMode.OLD_ONLY).create("Late v1", "v1@example.org"))
                .hasMessageContaining("customer_full_name_nn");
    }

    @Test
    @Order(5)
    void contract_serves_v4_only() throws Exception {
        applyPhase("contract");
        exercise(SchemaMode.NEW_ONLY);
        Integer oldCols = jdbc().queryForObject(
                "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'customer' AND column_name = 'customer_name'",
                Integer.class);
        assertThat(oldCols).isZero();
    }
}
