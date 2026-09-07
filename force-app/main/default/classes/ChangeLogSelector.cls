/**
 * ChangeLogSelector
 *
 * Data access layer for the Change Log batch framework.
 * All SOQL is constructed dynamically. No field name is hardcoded for
 * Deployment_Window__c or Change_Log__c.
 *
 * Security posture:
 *   - SetupChangeLog does not support WITH SECURITY_ENFORCED; callers that
 *     need FLS enforcement should use Security.stripInaccessible() on results.
 *   - Deployment_Window__c queries use WITH SECURITY_ENFORCED.
 *   - Duplicate Change_Log__c lookup uses WITH SECURITY_ENFORCED.
 */
public with sharing class ChangeLogSelector {

    // ── SetupChangeLog Query ─────────────────────────────────────────────────

    /**
     * Returns a query locator over SetupChangeLog scoped by the last run
     * timestamp.  Filtering on CreatedById != null and excluding the automated
     * process user is done in SOQL for performance.
     *
     * If lastRun is null, returns the last LOOKBACK_MONTHS months of records.
     */
    public Database.QueryLocator getSetupChangeLogLocator(DateTime lastRun) {
        String excludedUser = ChangeLogConstants.EXCLUDE_AUTOMATED;

        // Build the SELECT — only use stable standard fields on SetupChangeLog
        String baseQuery =
            'SELECT Id, CreatedDate, CreatedById, CreatedBy.Name, '
            + 'Action, Section, Display, DelegateUser '
            + 'FROM SetupChangeLog '
            + 'WHERE CreatedById != null '
            + 'AND CreatedBy.Name != :excludedUser';

        if (lastRun != null) {
            baseQuery += ' AND CreatedDate > :lastRun ORDER BY CreatedDate ASC';
            return Database.getQueryLocator(baseQuery);
        } else {
            DateTime cutoff = System.now().addMonths(-ChangeLogConstants.LOOKBACK_MONTHS);
            baseQuery += ' AND CreatedDate >= :cutoff ORDER BY CreatedDate ASC';
            return Database.getQueryLocator(baseQuery);
        }
    }

    // ── Deployment Window Query ───────────────────────────────────────────────

    /**
     * Queries all active Deployment_Window__c records using field names resolved
     * by ChangeLogMetadataService at runtime.
     *
     * @param dwSchema - resolved field names for the deployment window object
     * @return list of SObjects; callers access fields by dynamic get()
     */
    public List<SObject> getActiveDeploymentWindows(
            ChangeLogMetadataService.DeploymentWindowSchema dwSchema) {

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
            ChangeLogErrorService.logError('ChangeLogSelector.getActiveDeploymentWindows', e, null);
            return new List<SObject>();
        }
    }

    // ── Duplicate Change Log Check ───────────────────────────────────────────

    /**
     * Returns External_Id__c values already present in Change_Log__c so the
     * mapping service can skip records that were processed in a previous run.
     *
     * @param satIds — Set of SetupChangeLog Ids to check
     * @return Set of External_Id values already inserted
     */
    public Set<String> getExistingExternalIds(Set<String> satIds) {
        Set<String> existing = new Set<String>();
        if (satIds == null || satIds.isEmpty()) return existing;

        String targetObj = ChangeLogConstants.DEFAULT_TARGET_OBJECT;
        String extIdField = ChangeLogConstants.TARGET_EXT_ID;

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
            ChangeLogErrorService.logError('ChangeLogSelector.getExistingExternalIds', e, null);
        }
        return existing;
    }
}