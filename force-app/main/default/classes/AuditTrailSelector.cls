/**
 * AuditTrailSelector
 *
 * Data access layer for the audit trail batch framework.
 * All SOQL is constructed dynamically. No field name is hardcoded for
 * Deployment_Window__c or Audit_Trail__c.
 *
 * Security posture:
 *   - SetupAuditTrail does not support WITH SECURITY_ENFORCED; callers that
 *     need FLS enforcement should use Security.stripInaccessible() on results.
 *   - Deployment_Window__c queries use WITH SECURITY_ENFORCED.
 *   - Duplicate Audit_Trail__c lookup uses WITH SECURITY_ENFORCED.
 */
public with sharing class AuditTrailSelector {

    // ── SetupAuditTrail Query ─────────────────────────────────────────────────

    /**
     * Returns a query locator over SetupAuditTrail scoped by the last run
     * timestamp.  Filtering on CreatedById != null and excluding the automated
     * process user is done in SOQL for performance.
     *
     * If lastRun is null, returns the last LOOKBACK_MONTHS months of records.
     */
    public Database.QueryLocator getSetupAuditTrailLocator(DateTime lastRun) {
        String excludedUser = AuditTrailConstants.EXCLUDE_AUTOMATED;

        // Build the SELECT — only use stable standard fields on SetupAuditTrail
        String baseQuery =
            'SELECT Id, CreatedDate, CreatedById, CreatedBy.Name, '
            + 'Action, Section, Display, DelegateUser '
            + 'FROM SetupAuditTrail '
            + 'WHERE CreatedById != null '
            + 'AND CreatedBy.Name != :excludedUser';

        if (lastRun != null) {
            baseQuery += ' AND CreatedDate > :lastRun ORDER BY CreatedDate ASC';
            return Database.getQueryLocator(baseQuery);
        } else {
            DateTime cutoff = System.now().addMonths(-AuditTrailConstants.LOOKBACK_MONTHS);
            baseQuery += ' AND CreatedDate >= :cutoff ORDER BY CreatedDate ASC';
            return Database.getQueryLocator(baseQuery);
        }
    }

    // ── Deployment Window Query ───────────────────────────────────────────────

    /**
     * Queries all active Deployment_Window__c records using field names resolved
     * by AuditTrailMetadataService at runtime.
     *
     * @param dwSchema - resolved field names for the deployment window object
     * @return list of SObjects; callers access fields by dynamic get()
     */
    public List<SObject> getActiveDeploymentWindows(
            AuditTrailMetadataService.DeploymentWindowSchema dwSchema) {

        if (dwSchema == null) return new List<SObject>();

        String soql;
        if (dwSchema.isStatusBoolean) {
            soql = 'SELECT Id, ' + dwSchema.startField + ', ' + dwSchema.endField
                + ', ' + dwSchema.statusField
                + ' FROM ' + dwSchema.objectApiName
                + ' WHERE ' + dwSchema.statusField + ' = true'
                + ' WITH SECURITY_ENFORCED';
        } else {
            String activeVal = dwSchema.activeValue;
            soql = 'SELECT Id, ' + dwSchema.startField + ', ' + dwSchema.endField
                + ', ' + dwSchema.statusField
                + ' FROM ' + dwSchema.objectApiName
                + ' WHERE ' + dwSchema.statusField + ' = :activeVal'
                + ' WITH SECURITY_ENFORCED';
        }

        try {
            return Database.query(soql);
        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailSelector.getActiveDeploymentWindows', e, null);
            return new List<SObject>();
        }
    }

    // ── Duplicate Audit Trail Check ───────────────────────────────────────────

    /**
     * Returns External_Id__c values already present in Audit_Trail__c so the
     * mapping service can skip records that were processed in a previous run.
     *
     * @param satIds — Set of SetupAuditTrail Ids to check
     * @return Set of External_Id values already inserted
     */
    public Set<String> getExistingExternalIds(Set<String> satIds) {
        Set<String> existing = new Set<String>();
        if (satIds == null || satIds.isEmpty()) return existing;

        String targetObj = AuditTrailConstants.DEFAULT_TARGET_OBJECT;
        String extIdField = AuditTrailConstants.TARGET_EXT_ID;

        // Verify object and field exist before querying
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(targetObj.toLowerCase())) return existing;
        Map<String, Schema.SObjectField> fieldMap =
            gd.get(targetObj.toLowerCase()).getDescribe().fields.getMap();
        if (!fieldMap.containsKey(extIdField.toLowerCase())) return existing;

        String soql = 'SELECT ' + extIdField
            + ' FROM ' + targetObj
            + ' WHERE ' + extIdField + ' IN :satIds'
            + ' WITH SECURITY_ENFORCED';

        try {
            for (SObject rec : Database.query(soql)) {
                existing.add((String) rec.get(extIdField));
            }
        } catch (Exception e) {
            AuditTrailErrorService.logError('AuditTrailSelector.getExistingExternalIds', e, null);
        }
        return existing;
    }
}