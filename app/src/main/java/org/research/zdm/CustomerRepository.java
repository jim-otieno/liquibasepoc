package org.research.zdm;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

/**
 * Application-layer dual-write.
 *
 * Old (customer_name) and new (full_name) columns live in the same database,
 * so one local transaction writes both atomically - no distributed dual-write
 * problem. The repository never references a column that the current mode's
 * valid schema states might not have.
 */
@Repository
public class CustomerRepository {

    private static final Logger log = LoggerFactory.getLogger(CustomerRepository.class);

    private final JdbcTemplate jdbc;
    private final SchemaMode mode;
    private final Counter shadowReads;
    private final Counter shadowMismatches;

    public CustomerRepository(JdbcTemplate jdbc, AppProperties props, MeterRegistry registry) {
        this.jdbc = jdbc;
        this.mode = props.schemaMode();
        this.shadowReads = Counter.builder("zdm.shadow.reads")
                .description("Reads compared between old and new columns").register(registry);
        this.shadowMismatches = Counter.builder("zdm.shadow.mismatches")
                .description("Reads where old and new column values differ").register(registry);
        registry.gauge("zdm.schema.mode", mode.ordinal());
        log.info("Customer repository running in schema mode {}", mode);
    }

    public SchemaMode mode() {
        return mode;
    }

    @Transactional
    public Customer create(String name, String email) {
        List<String> cols = new ArrayList<>();
        List<Object> args = new ArrayList<>();
        if (mode.writeOld) {
            cols.add("customer_name");
            args.add(name);
        }
        if (mode.writeNew) {
            cols.add("full_name");
            args.add(name);
        }
        cols.add("email");
        args.add(email);

        String sql = "INSERT INTO customer (" + String.join(", ", cols) + ") VALUES ("
                + String.join(", ", cols.stream().map(c -> "?").toList()) + ")";
        KeyHolder keys = new GeneratedKeyHolder();
        jdbc.update(con -> {
            var ps = con.prepareStatement(sql, new String[] {"id"});
            for (int i = 0; i < args.size(); i++) {
                ps.setObject(i + 1, args.get(i));
            }
            return ps;
        }, keys);
        Number id = Objects.requireNonNull(keys.getKey(), "no generated id");
        return new Customer(id.longValue(), name, email);
    }

    @Transactional
    public boolean rename(long id, String name) {
        String set;
        Object[] args;
        if (mode.writeOld && mode.writeNew) {
            set = "customer_name = ?, full_name = ?";
            args = new Object[] {name, name, id};
        } else if (mode.writeNew) {
            set = "full_name = ?";
            args = new Object[] {name, id};
        } else {
            set = "customer_name = ?";
            args = new Object[] {name, id};
        }
        return jdbc.update("UPDATE customer SET " + set + " WHERE id = ?", args) == 1;
    }

    public Optional<Customer> find(long id) {
        if (mode.shadowRead()) {
            return jdbc.query("SELECT id, customer_name, full_name, email FROM customer WHERE id = ?",
                    rs -> {
                        if (!rs.next()) {
                            return Optional.<Customer>empty();
                        }
                        String oldVal = rs.getString("customer_name");
                        String newVal = rs.getString("full_name");
                        shadowReads.increment();
                        // A NULL new value before the backfill reaches this row is expected, not a mismatch.
                        if (newVal != null && !newVal.equals(oldVal)) {
                            shadowMismatches.increment();
                            log.warn("shadow-read mismatch id={} old='{}' new='{}'", id, oldVal, newVal);
                        }
                        return Optional.of(new Customer(rs.getLong("id"), oldVal, rs.getString("email")));
                    }, id);
        }
        String col = mode.readNew ? "full_name" : "customer_name";
        List<Customer> rows = jdbc.query("SELECT id, " + col + " AS name, email FROM customer WHERE id = ?",
                (rs, n) -> new Customer(rs.getLong("id"), rs.getString("name"), rs.getString("email")), id);
        return rows.stream().findFirst();
    }
}
