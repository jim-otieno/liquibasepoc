package org.research.zdm;

/**
 * Application modes of the expand/contract phase model.
 * Each release of the service is the same code started in a different mode
 * (env APP_SCHEMA_MODE), so the experiment varies only the data path.
 *
 * <pre>
 * mode                 app   writes        reads   valid schema states
 * OLD_ONLY             v1    old           old     baseline, after expand
 * DUAL_WRITE_READ_OLD  v2    old + new     old     after expand .. after harden
 * DUAL_WRITE_READ_NEW  v3    old + new     new     after migrate .. after harden
 * NEW_ONLY             v4    new           new     after harden, after contract
 * </pre>
 */
public enum SchemaMode {
    OLD_ONLY(true, false, false),
    DUAL_WRITE_READ_OLD(true, true, false),
    DUAL_WRITE_READ_NEW(true, true, true),
    NEW_ONLY(false, true, true);

    public final boolean writeOld;
    public final boolean writeNew;
    public final boolean readNew;

    SchemaMode(boolean writeOld, boolean writeNew, boolean readNew) {
        this.writeOld = writeOld;
        this.writeNew = writeNew;
        this.readNew = readNew;
    }

    /** v2 compares old and new values on every read before the read path switches. */
    public boolean shadowRead() {
        return this == DUAL_WRITE_READ_OLD;
    }
}
