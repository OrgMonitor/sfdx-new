/** Calculates digest business content once for all provider renderers. */
public without sharing class OrgMonitorChangeDigestBuilder {
    public OrgMonitorChangeDigestModel build(List<Change_Log__c> rows, String correlationId,
            Datetime periodStart, Datetime periodEnd, String orgTimeZoneSidKey) {
        if (rows == null || rows.isEmpty()) return null;
        OrgMonitorChangeDigestModel digest = new OrgMonitorChangeDigestModel();
        digest.effectiveActorId = rows[0].Effective_Actor__c;
        digest.effectiveActorName = rows[0].Effective_Actor__r == null
            ? String.valueOf(rows[0].Effective_Actor__c) : rows[0].Effective_Actor__r.Name;
        digest.periodStart = periodStart; digest.periodEnd = periodEnd;
        digest.orgTimeZoneSidKey = orgTimeZoneSidKey; digest.correlationId = correlationId;
        digest.reviewUrl = buildReviewUrl();
        Map<String, OrgMonitorChangeDigestModel.ReasonSummary> reasons =
            new Map<String, OrgMonitorChangeDigestModel.ReasonSummary>();

        for (Change_Log__c row : rows) {
            digest.totalCount++;
            if (row.Non_Compliant__c != true) { digest.compliantCount++; continue; }
            digest.nonCompliantCount++;
            if (row.Severity__c == 'CRITICAL') {
                digest.criticalNonCompliantCount++;
                digest.criticalChanges.add(criticalItem(row, digest.effectiveActorName));
            } else if (row.Severity__c == 'HIGH') digest.highNonCompliantCount++;
            else if (row.Severity__c == 'MEDIUM') digest.mediumNonCompliantCount++;
            else if (row.Severity__c == 'LOW') digest.lowNonCompliantCount++;
            else digest.otherNonCompliantCount++;
            addReason(reasons, row, digest.effectiveActorName);
        }
        digest.nonComplianceReasons.addAll(reasons.values());
        digest.nonComplianceReasons.sort(new ReasonOrder());
        return digest;
    }

    private OrgMonitorChangeDigestModel.CriticalChangeItem criticalItem(
            Change_Log__c row, String actorName) {
        OrgMonitorChangeDigestModel.CriticalChangeItem item =
            new OrgMonitorChangeDigestModel.CriticalChangeItem();
        item.changeLogId = row.Id; item.readableOperation = operation(row.Change_Operation__c);
        item.metadataType = metadataLabel(row.Metadata_Type__c);
        item.componentName = row.Component_Name__c; item.changeTime = row.Log_Created_Date__c;
        item.conciseReason = reason(row.Compliance_Reason_Code__c,
            row.Matched_Deployment_Window__r == null ? null : row.Matched_Deployment_Window__r.Name,
            actorName);
        item.delegatedAccess = row.Is_Delegated_Access__c == true;
        item.effectiveActorName = actorName;
        item.actingAsUserName = row.Change_Operation__c == 'ACCESS_EVENT'
                && row.Effective_Actor__c == row.Changed_By_User__c
            ? row.Component_Name__c
            : row.Changed_By_User__r == null ? null : row.Changed_By_User__r.Name;
        return item;
    }
    private void addReason(Map<String, OrgMonitorChangeDigestModel.ReasonSummary> reasons,
            Change_Log__c row, String actorName) {
        String windowId = String.valueOf(row.Matched_Deployment_Window__c);
        String key = row.Compliance_Reason_Code__c + '|' + windowId;
        if (!reasons.containsKey(key)) {
            OrgMonitorChangeDigestModel.ReasonSummary summary =
                new OrgMonitorChangeDigestModel.ReasonSummary();
            summary.reasonCode = row.Compliance_Reason_Code__c;
            summary.windowName = row.Matched_Deployment_Window__r == null
                ? null : row.Matched_Deployment_Window__r.Name;
            summary.conciseText = reason(summary.reasonCode, summary.windowName, actorName);
            summary.count = 0; reasons.put(key, summary);
        }
        reasons.get(key).count++;
    }
    public static String operation(String value) {
        Map<String, String> labels = new Map<String, String>{
            'CREATE_OR_ADD' => 'Created', 'UPDATE' => 'Updated',
            'DELETE_OR_REMOVE' => 'Deleted', 'ENABLE' => 'Enabled',
            'ACTIVATE_OR_ENABLE' => 'Enabled', 'DISABLE' => 'Disabled',
            'DEACTIVATE_OR_DISABLE' => 'Disabled', 'ASSIGN' => 'Assigned',
            'REMOVE' => 'Removed', 'ACCESS_EVENT' => 'Accessed',
            'Logged In As' => 'Logged in as'
        };
        return labels.containsKey(value) ? labels.get(value) : 'Changed';
    }
    public static String metadataLabel(String value) {
        Map<String, String> labels = new Map<String, String>{
            'ApexClass' => 'Apex class', 'PermissionSet' => 'Permission set',
            'CustomObject' => 'Custom object', 'CustomField' => 'Custom field',
            'NamedCredential' => 'Named credential', 'ConnectedApp' => 'Connected app',
            'Flow' => 'Flow'
        };
        return labels.containsKey(value) ? labels.get(value)
            : String.isBlank(value) || value == 'Unclassified' ? 'setup component' : value;
    }
    public static String reason(String code, String windowName, String actorName) {
        if (code == 'WINDOW_NOT_APPROVED') return 'The deployment window was not approved before the change.';
        if (code == 'USER_NOT_NOMINATED') return actorName + ' was not nominated for deployment window '
            + (String.isBlank(windowName) ? '(unavailable)' : windowName) + '.';
        if (code == 'INVALID_WINDOW_CONFIGURATION') return 'Deployment window '
            + (String.isBlank(windowName) ? '(unavailable)' : windowName)
            + ' had invalid or incomplete configuration.';
        return 'No deployment window covered this change.';
    }
    private String buildReviewUrl() {
        try {
            String objectName = Change_Log__c.SObjectType.getDescribe().getName();
            return URL.getOrgDomainUrl().toExternalForm() + '/lightning/o/' + objectName + '/list';
        } catch (Exception ignored) { return null; }
    }
    private class ReasonOrder implements Comparator<OrgMonitorChangeDigestModel.ReasonSummary> {
        public Integer compare(OrgMonitorChangeDigestModel.ReasonSummary left,
                OrgMonitorChangeDigestModel.ReasonSummary right) {
            if (left.count != right.count) return right.count - left.count;
            return (left.reasonCode + '|' + left.windowName).compareTo(right.reasonCode + '|' + right.windowName);
        }
    }
}