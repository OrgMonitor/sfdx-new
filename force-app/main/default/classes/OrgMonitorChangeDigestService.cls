/** Builds one structured digest per effective actor and hands it to the existing dispatcher. */
public without sharing class OrgMonitorChangeDigestService {
    private static final Integer MAX_CRITICAL_ITEMS_PER_MESSAGE = 30;
    public static void dispatch(String correlationId, Datetime periodStart, Datetime periodEnd,
            String orgTimeZoneSidKey) {
        List<Change_Log__c> rows = [
            SELECT Id, Effective_Actor__c, Effective_Actor__r.Name,
                   Changed_By_User__c, Changed_By_User__r.Name, Is_Delegated_Access__c,
                   Log_Created_Date__c, Severity__c, Non_Compliant__c,
                   Compliance_Reason_Code__c, Matched_Deployment_Window__c,
                   Matched_Deployment_Window__r.Name, Change_Operation__c,
                   Metadata_Type__c, Component_Name__c
            FROM Change_Log__c
            WHERE Run_Correlation_Id__c = :correlationId
            ORDER BY Effective_Actor__c, Log_Created_Date__c, Id
        ];
        if (rows.isEmpty()) return;
        Map<Id, List<Change_Log__c>> byActor = new Map<Id, List<Change_Log__c>>();
        for (Change_Log__c row : rows) {
            if (!byActor.containsKey(row.Effective_Actor__c))
                byActor.put(row.Effective_Actor__c, new List<Change_Log__c>());
            byActor.get(row.Effective_Actor__c).add(row);
        }
        List<Id> actorIds = new List<Id>(byActor.keySet()); actorIds.sort();
        List<OrgMonitorNotificationService.NotificationRequest> requests =
            new List<OrgMonitorNotificationService.NotificationRequest>();
        OrgMonitorChangeDigestBuilder builder = new OrgMonitorChangeDigestBuilder();
        OrgMonitorChangeDigestRenderer renderer = new OrgMonitorChangeDigestRenderer();
        for (Id actorId : actorIds) {
            OrgMonitorChangeDigestModel digest = builder.build(byActor.get(actorId), correlationId,
                periodStart, periodEnd, orgTimeZoneSidKey);
            List<OrgMonitorChangeDigestModel> parts = splitCriticalChanges(digest);
            for (Integer partIndex = 0; partIndex < parts.size(); partIndex++) {
                Integer partNumber = partIndex + 1;
                OrgMonitorChangeDigestRenderer.RenderedDigest rendered = renderer.render(
                    parts[partIndex], partNumber, parts.size());
                OrgMonitorNotificationService.NotificationRequest request =
                    new OrgMonitorNotificationService.NotificationRequest();
                request.title = rendered.title;
                request.message = rendered.slackFallbackText;
                request.slackFallbackText = rendered.slackFallbackText;
                request.slackBlocksJson = rendered.slackBlocksJson;
                request.teamsHtml = rendered.teamsHtml;
                request.sourceRecordId = byActor.get(actorId)[0].Id;
                request.actorIdentifier = String.valueOf(actorId);
                request.periodStart = periodStart; request.periodEnd = periodEnd;
                request.changeCount = digest.totalCount; request.correlationId = correlationId;
                request.idempotencyKey = 'ORG_MONITOR_CHANGE_DIGEST:'
                    + periodEnd.formatGMT('yyyyMMddHHmmssSSS') + ':' + actorId + ':' + partNumber;
                requests.add(request);
            }
        }
        for (Integer offset = 0; offset < requests.size(); offset += 50) {
            List<OrgMonitorNotificationService.NotificationRequest> dispatchGroup =
                new List<OrgMonitorNotificationService.NotificationRequest>();
            for (Integer index = offset; index < Math.min(offset + 50, requests.size()); index++)
                dispatchGroup.add(requests[index]);
            OrgMonitorNotificationService.send(dispatchGroup);
        }
    }

    @TestVisible
    private static List<OrgMonitorChangeDigestModel> splitCriticalChanges(OrgMonitorChangeDigestModel source) {
        List<OrgMonitorChangeDigestModel> parts = new List<OrgMonitorChangeDigestModel>();
        Integer partCount = Math.max(1, (Integer)Math.ceil(
            Decimal.valueOf(source.criticalChanges.size()) / MAX_CRITICAL_ITEMS_PER_MESSAGE));
        for (Integer partIndex = 0; partIndex < partCount; partIndex++) {
            OrgMonitorChangeDigestModel part = (OrgMonitorChangeDigestModel)JSON.deserialize(
                JSON.serialize(source), OrgMonitorChangeDigestModel.class);
            part.criticalChanges.clear();
            Integer first = partIndex * MAX_CRITICAL_ITEMS_PER_MESSAGE;
            Integer last = Math.min(first + MAX_CRITICAL_ITEMS_PER_MESSAGE, source.criticalChanges.size());
            for (Integer itemIndex = first; itemIndex < last; itemIndex++)
                part.criticalChanges.add(source.criticalChanges[itemIndex]);
            parts.add(part);
        }
        return parts;
    }

    /** Compatibility overload for existing callers; production batch supplies its run snapshot. */
    public static void dispatch(String correlationId, Datetime periodStart, Datetime periodEnd) {
        String orgTimeZoneSidKey = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
        dispatch(correlationId, periodStart, periodEnd, orgTimeZoneSidKey);
    }
}