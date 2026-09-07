/**
 * Durable provider-neutral notification dispatcher for Org Monitor.
 * Callers supply content only; configuration and destinations are always loaded
 * from the org-level ChangeLogRuntime__c setting.
 */
public without sharing class OrgMonitorNotificationService {
    private static final Integer MAX_REQUESTS = 50;
    private static final String SLACK = 'Slack';
    private static final String TEAMS = 'Microsoft Teams';

    public class NotificationRequest {
        public String message;
        public String title;
        public Id sourceRecordId;
        public String actorIdentifier;
        public Datetime periodStart;
        public Datetime periodEnd;
        public Integer changeCount;
        public String correlationId;
        public String idempotencyKey;
        public String slackFallbackText;
        public String slackBlocksJson;
        public String teamsHtml;
    }

    public class DispatchResult {
        public String provider;
        public String state;
        public Id notificationId;
        public String detail;
        private DispatchResult(String provider, String state, Id notificationId, String detail) {
            this.provider = provider;
            this.state = state;
            this.notificationId = notificationId;
            this.detail = detail;
        }
    }

    private class Candidate {
        String provider;
        String dedupeKey;
        Governance_Notification__c record;
        Candidate(String provider, String dedupeKey, Governance_Notification__c record) {
            this.provider = provider; this.dedupeKey = dedupeKey; this.record = record;
        }
    }

    public static List<DispatchResult> send(NotificationRequest request) {
        return send(new List<NotificationRequest>{ request });
    }

    public static List<DispatchResult> send(List<NotificationRequest> requests) {
        if (requests == null || requests.isEmpty()) return new List<DispatchResult>();
        if (requests.size() > MAX_REQUESTS) {
            throw new OrgMonitorNotificationException('A maximum of 50 requests can be dispatched at once.');
        }

        ChangeLogRuntime__c settings = ChangeLogRuntime__c.getOrgDefaults();
        List<DispatchResult> results = new List<DispatchResult>();
        List<Candidate> candidates = new List<Candidate>();

        for (NotificationRequest request : requests) {
            validateRequest(request);
            evaluateSlack(request, settings, candidates, results);
            evaluateTeams(request, settings, candidates, results);
        }
        if (candidates.isEmpty()) return results;

        Set<String> keys = new Set<String>();
        for (Candidate candidate : candidates) keys.add(candidate.dedupeKey);
        Set<String> existing = new Set<String>();
        for (Governance_Notification__c row : [
            SELECT Id, Idempotency_Key__c FROM Governance_Notification__c
            WHERE Idempotency_Key__c IN :keys
        ]) existing.add(row.Idempotency_Key__c);

        List<Candidate> pending = new List<Candidate>();
        for (Candidate candidate : candidates) {
            if (existing.contains(candidate.dedupeKey)) {
                results.add(new DispatchResult(candidate.provider, 'DUPLICATE', null, null));
            } else {
                pending.add(candidate);
            }
        }

        if (!pending.isEmpty()) {
            List<Governance_Notification__c> rows = new List<Governance_Notification__c>();
            for (Candidate candidate : pending) rows.add(candidate.record);
            List<Database.SaveResult> saves = Database.insert(rows, false);
            List<Id> queuedIds = new List<Id>();
            for (Integer i = 0; i < saves.size(); i++) {
                if (saves[i].isSuccess()) {
                    queuedIds.add(saves[i].getId());
                    results.add(new DispatchResult(pending[i].provider, 'QUEUED', saves[i].getId(), null));
                } else if (isDuplicate(saves[i])) {
                    results.add(new DispatchResult(pending[i].provider, 'DUPLICATE', null, null));
                } else {
                    throw new OrgMonitorNotificationException('Notification dispatch could not be prepared.');
                }
            }
            if (!queuedIds.isEmpty()) System.enqueueJob(new OrgMonitorNotificationQueueable(queuedIds));
        }
        return results;
    }

    private static void evaluateSlack(NotificationRequest request, ChangeLogRuntime__c settings,
            List<Candidate> candidates, List<DispatchResult> results) {
        Boolean eligible = settings != null
            && settings.Slack_Notifications_Enabled__c == true
            && settings.Slack_Last_Test__c != null
            && String.isNotBlank(settings.Slack_Channel_Id__c);
        if (!eligible) {
            results.add(new DispatchResult(SLACK, 'SKIPPED', null, 'Provider is disabled or incomplete.'));
            return;
        }
        candidates.add(buildCandidate(request, SLACK, settings.Slack_Channel_Id__c,
            settings.Slack_Channel_Name__c, null));
    }

    private static void evaluateTeams(NotificationRequest request, ChangeLogRuntime__c settings,
            List<Candidate> candidates, List<DispatchResult> results) {
        Boolean eligible = settings != null
            && settings.Teams_Notifications_Enabled__c == true
            && settings.Teams_Last_Test__c != null
            && String.isNotBlank(settings.Teams_Team_Id__c)
            && String.isNotBlank(settings.Teams_Channel_Id__c);
        if (!eligible) {
            results.add(new DispatchResult(TEAMS, 'SKIPPED', null, 'Provider is disabled or incomplete.'));
            return;
        }
        candidates.add(buildCandidate(request, TEAMS, settings.Teams_Channel_Id__c,
            settings.Teams_Channel_Name__c, settings.Teams_Team_Id__c));
    }

    private static Candidate buildCandidate(NotificationRequest request, String provider,
            String destinationId, String destinationName, String teamId) {
        String key = dedupeKey(request.idempotencyKey, provider, destinationId);
        Boolean slackBlocks = provider == SLACK && String.isNotBlank(request.slackBlocksJson);
        Boolean teamsHtml = provider == TEAMS && String.isNotBlank(request.teamsHtml);
        Governance_Notification__c row = new Governance_Notification__c(
            Provider__c = provider,
            Status__c = 'Pending',
            Title__c = trimTo(request.title, 255),
            Fallback_Text__c = slackBlocks ? trimTo(request.slackFallbackText, 1000) : null,
            Message__c = slackBlocks ? request.slackBlocksJson
                : teamsHtml ? request.teamsHtml : request.message,
            Content_Format__c = slackBlocks ? 'SLACK_BLOCKS'
                : teamsHtml ? 'TEAMS_HTML' : 'PLAIN_TEXT',
            Source_Record_Id__c = request.sourceRecordId == null ? null : String.valueOf(request.sourceRecordId),
            Actor_Identifier__c = trimTo(request.actorIdentifier, 255),
            Period_Start__c = request.periodStart,
            Period_End__c = request.periodEnd,
            Change_Count__c = request.changeCount,
            Correlation_Id__c = trimTo(request.correlationId, 255),
            Idempotency_Key__c = key,
            Destination_Id__c = trimTo(destinationId, 255),
            Destination_Name__c = trimTo(destinationName, 255),
            Team_Id__c = trimTo(teamId, 255),
            Attempt_Count__c = 0
        );
        return new Candidate(provider, key, row);
    }

    private static String dedupeKey(String supplied, String provider, String destinationId) {
        if (String.isBlank(supplied)) {
            return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',
                Blob.valueOf(provider + '|' + destinationId + '|' + Crypto.getRandomLong())));
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',
            Blob.valueOf(supplied.trim() + '|' + provider + '|' + destinationId)));
    }

    private static void validateRequest(NotificationRequest request) {
        if (request == null || String.isBlank(request.message)) {
            throw new OrgMonitorNotificationException('Notification message is required.');
        }
        if (request.message.length() > 32000) {
            throw new OrgMonitorNotificationException('Notification message is too long.');
        }
        if (request.changeCount != null && request.changeCount < 0) {
            throw new OrgMonitorNotificationException('Change count cannot be negative.');
        }
        if (request.periodStart != null && request.periodEnd != null
                && request.periodEnd < request.periodStart) {
            throw new OrgMonitorNotificationException('Period end cannot be before period start.');
        }
    }

    private static Boolean isDuplicate(Database.SaveResult result) {
        for (Database.Error error : result.getErrors()) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) return true;
        }
        return false;
    }
    private static String trimTo(String value, Integer size) {
        return value == null ? null : value.left(Math.min(value.length(), size));
    }

    public class OrgMonitorNotificationException extends Exception {}
}