/**
 * AuditTrailService
 *
 * Business logic orchestrator — enforces sharing rules (with sharing).
 * Called from AuditTrailBatch.execute() for each scope chunk.
 *
 * Responsibilities per chunk:
 *   1. Fetch active Deployment_Window__c records (once per service instance,
 *      cached for the chunk's lifetime).
 *   2. Load severity rules from metadata (cached at metadata service level).
 *   3. For each SAT record: resolve severity → evaluate compliance → map to target.
 *   4. Skip duplicates via External_Id__c check.
 *   5. Upsert target records using the external ID field for idempotency.
 *   6. Log all DML errors via AuditTrailErrorService.
 *
 * No SOQL or DML is performed inside loops.
 */
public with sharing class AuditTrailService {

    // ── Dependencies ──────────────────────────────────────────────────────────
    private final AuditTrailMetadataService   metaSvc;
    private final AuditTrailSelector          selector;
    private final AuditTrailComplianceService complianceSvc;
    private final AuditTrailMappingService    mappingSvc;

    // ── Chunk-level cache for deployment windows ───────────────────────────────
    private List<SObject>                                    cachedWindows;
    private AuditTrailMetadataService.DeploymentWindowSchema cachedDwSchema;

    // ── Constructor ───────────────────────────────────────────────────────────
    public AuditTrailService() {
        this.metaSvc       = new AuditTrailMetadataService();
        this.selector      = new AuditTrailSelector();
        this.complianceSvc = new AuditTrailComplianceService();
        this.mappingSvc    = new AuditTrailMappingService(this.metaSvc);
    }

    /** DI constructor for testability. */
    @TestVisible
    private AuditTrailService(
            AuditTrailMetadataService   metaSvc,
            AuditTrailSelector          selector,
            AuditTrailComplianceService complianceSvc,
            AuditTrailMappingService    mappingSvc) {
        this.metaSvc       = metaSvc;
        this.selector      = selector;
        this.complianceSvc = complianceSvc;
        this.mappingSvc    = mappingSvc;
    }

    // ── Main Process Method ───────────────────────────────────────────────────
    /**
     * Processes a batch scope of SetupAuditTrail SObjects.
     * Returns the count of records successfully upserted.
     */
    public Integer process(List<SObject> satRecords) {
        if (satRecords == null || satRecords.isEmpty()) return 0;

        AuditTrailErrorService.clearBuffer();

        try {
            // Step 1: Resolve deployment window schema + fetch active windows once
            if (cachedDwSchema == null) {
                try {
                    cachedDwSchema = metaSvc.getDeploymentWindowSchema();
                    cachedWindows  = selector.getActiveDeploymentWindows(cachedDwSchema);
                } catch (AuditTrailException e) {
                    AuditTrailErrorService.logError(
                        'AuditTrailService.process.dwSchemaDiscovery', e, null);
                    cachedWindows = new List<SObject>();
                }
            }

            // Step 2: Load severity rules
            List<AuditTrailMetadataService.SeverityRule> rules = metaSvc.getSeverityRules();

            // Step 3: Resolve severity for each record (no SOQL in loop — rules cached)
            Map<Id, String> severityMap = new Map<Id, String>();
            for (SObject satRec : satRecords) {
                Id satId = (Id) satRec.get(AuditTrailConstants.SAT_ID);
                severityMap.put(satId, mappingSvc.resolveSeverity(satRec, rules));
            }

            // Step 4: Evaluate compliance in bulk
            Map<Id, AuditTrailComplianceService.ComplianceResult> complianceMap =
                complianceSvc.evaluate(satRecords, cachedWindows, cachedDwSchema);

            // Step 5: Collect existing external IDs to avoid duplicates
            Set<String> satIdStrings = new Set<String>();
            for (SObject satRec : satRecords) {
                satIdStrings.add(String.valueOf(satRec.get(AuditTrailConstants.SAT_ID)));
            }
            Set<String> existingExtIds = selector.getExistingExternalIds(satIdStrings);

            // Step 6: Map SAT records → target SObjects
            List<SObject> targetRecords = mappingSvc.mapRecords(
                satRecords, severityMap, complianceMap, existingExtIds);

            if (targetRecords.isEmpty()) return 0;

            // Step 7: Upsert with partial success (External_Id__c as key)
            Schema.SObjectField extIdField = getExternalIdField();
            Integer successCount = 0;

            if (extIdField != null) {
                List<Database.UpsertResult> upsertResults =
                    Database.upsert(targetRecords, extIdField, false);
                AuditTrailErrorService.processUpsertResults(
                    upsertResults, targetRecords, 'AuditTrailService.process.upsert');
                for (Database.UpsertResult ur : upsertResults) {
                    if (ur.isSuccess()) successCount++;
                }
            } else {
                // Fallback to insert if external ID field not resolved
                List<Database.SaveResult> saveResults =
                    Database.insert(targetRecords, false);
                AuditTrailErrorService.processSaveResults(
                    saveResults, targetRecords, 'AuditTrailService.process.insert');
                for (Database.SaveResult sr : saveResults) {
                    if (sr.isSuccess()) successCount++;
                }
            }

            return successCount;

        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailService.process', e, null);
            return 0;
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────
    private Schema.SObjectField getExternalIdField() {
        String targetObj   = AuditTrailConstants.DEFAULT_TARGET_OBJECT;
        String extIdField  = AuditTrailConstants.TARGET_EXT_ID;
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(targetObj.toLowerCase())) return null;

        Map<String, Schema.SObjectField> fieldMap =
            gd.get(targetObj.toLowerCase()).getDescribe().fields.getMap();

        return fieldMap.containsKey(extIdField.toLowerCase())
            ? fieldMap.get(extIdField.toLowerCase()) : null;
    }
}