/**
 * ChangeLogBatch
 *
 * Database.Batchable<SObject> entry point for the Change Log processing pipeline.
 *
 * start()   — builds a query locator against SetupChangeLog using the last run
 *             timestamp from Change_Log_Config__mdt.Default.
 * execute() — delegates each scope chunk to ChangeLogService.process().
 * finish()  — schedules an async CMT deployment to update Last_Run_Timestamp__c.
 *
 * Implements Database.Stateful to accumulate total processed count across chunks.
 */
public class ChangeLogBatch implements Database.Batchable<SObject>, Database.Stateful {

    // ── State (persisted across chunks via Database.Stateful) ────────────────
    @TestVisible private Integer  totalProcessed  = 0;
    @TestVisible private DateTime batchStartTime;
    @TestVisible private DateTime lastRunTimestamp;

    // ── Dependencies ──────────────────────────────────────────────────────────
    private final ChangeLogMetadataService metaSvc;
    private final ChangeLogSelector        selector;
    private final ChangeLogService         service;

    // ── Default Constructor ───────────────────────────────────────────────────
    public ChangeLogBatch() {
        this.metaSvc   = new ChangeLogMetadataService();
        this.selector  = new ChangeLogSelector();
        this.service   = new ChangeLogService();
    }

    /** DI constructor for testability. */
    @TestVisible
    private ChangeLogBatch(ChangeLogMetadataService metaSvc,
                            ChangeLogSelector selector,
                            ChangeLogService service) {
        this.metaSvc  = metaSvc;
        this.selector = selector;
        this.service  = service;
    }

    // ── start() ───────────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext bc) {
        batchStartTime = System.now();

        try {
            ChangeLogMetadataService.ChangeLogConfig config = metaSvc.getConfig();
            lastRunTimestamp = (config != null) ? config.lastRunTimestamp : null;
        } catch (Exception e) {
            ChangeLogErrorService.logError('ChangeLogBatch.start.loadConfig', e, null);
            lastRunTimestamp = null;
        }

        System.debug(LoggingLevel.INFO,
            '[ChangeLogBatch] start() — lastRunTimestamp=' + lastRunTimestamp);

        return selector.getSetupChangeLogLocator(lastRunTimestamp);
    }

    // ── execute() ─────────────────────────────────────────────────────────────
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        try {
            Integer chunkCount = service.process(scope);
            totalProcessed += chunkCount;
            System.debug(LoggingLevel.INFO,
                '[ChangeLogBatch] execute() — chunk=' + scope.size()
                + ', inserted/updated=' + chunkCount
                + ', totalProcessed=' + totalProcessed);
        } catch (Exception e) {
            ChangeLogErrorService.logError(
                'ChangeLogBatch.execute', e,
                'Batch chunk size: ' + scope.size());
        }
    }

    // ── finish() ──────────────────────────────────────────────────────────────
    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            '[ChangeLogBatch] finish() — totalProcessed=' + totalProcessed);

        // Update the CMT timestamp so the next run is incremental
        try {
            metaSvc.scheduleTimestampUpdate(batchStartTime);
        } catch (Exception e) {
            ChangeLogErrorService.logError('ChangeLogBatch.finish.timestampUpdate', e, null);
        }
    }
}