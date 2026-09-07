/**
 * AuditTrailBatch
 *
 * Database.Batchable<SObject> entry point for the audit trail processing pipeline.
 *
 * start()   — builds a query locator against SetupAuditTrail using the last run
 *             timestamp from Audit_Trail_Config__mdt.Default.
 * execute() — delegates each scope chunk to AuditTrailService.process().
 * finish()  — schedules an async CMT deployment to update Last_Run_Timestamp__c.
 *
 * Implements Database.Stateful to accumulate total processed count across chunks.
 */
public class AuditTrailBatch implements Database.Batchable<SObject>, Database.Stateful {

    // ── State (persisted across chunks via Database.Stateful) ────────────────
    @TestVisible private Integer  totalProcessed  = 0;
    @TestVisible private DateTime batchStartTime;
    @TestVisible private DateTime lastRunTimestamp;

    // ── Dependencies ──────────────────────────────────────────────────────────
    private final AuditTrailMetadataService metaSvc;
    private final AuditTrailSelector        selector;
    private final AuditTrailService         service;

    // ── Default Constructor ───────────────────────────────────────────────────
    public AuditTrailBatch() {
        this.metaSvc   = new AuditTrailMetadataService();
        this.selector  = new AuditTrailSelector();
        this.service   = new AuditTrailService();
    }

    /** DI constructor for testability. */
    @TestVisible
    private AuditTrailBatch(AuditTrailMetadataService metaSvc,
                            AuditTrailSelector selector,
                            AuditTrailService service) {
        this.metaSvc  = metaSvc;
        this.selector = selector;
        this.service  = service;
    }

    // ── start() ───────────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext bc) {
        batchStartTime = System.now();

        try {
            AuditTrailMetadataService.AuditTrailConfig config = metaSvc.getConfig();
            lastRunTimestamp = (config != null) ? config.lastRunTimestamp : null;
        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailBatch.start.loadConfig', e, null);
            lastRunTimestamp = null;
        }

        System.debug(LoggingLevel.INFO,
            '[AuditTrailBatch] start() — lastRunTimestamp=' + lastRunTimestamp);

        return selector.getSetupAuditTrailLocator(lastRunTimestamp);
    }

    // ── execute() ─────────────────────────────────────────────────────────────
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        try {
            Integer chunkCount = service.process(scope);
            totalProcessed += chunkCount;
            System.debug(LoggingLevel.INFO,
                '[AuditTrailBatch] execute() — chunk=' + scope.size()
                + ', inserted/updated=' + chunkCount
                + ', totalProcessed=' + totalProcessed);
        } catch (Exception e) {
            AuditTrailErrorService.logError(
                'AuditTrailBatch.execute', e,
                'Batch chunk size: ' + scope.size());
        }
    }

    // ── finish() ──────────────────────────────────────────────────────────────
    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            '[AuditTrailBatch] finish() — totalProcessed=' + totalProcessed);

        // Update the CMT timestamp so the next run is incremental
        try {
            metaSvc.scheduleTimestampUpdate(batchStartTime);
        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailBatch.finish.timestampUpdate', e, null);
        }
    }
}