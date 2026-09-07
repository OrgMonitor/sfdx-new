/** Performs provider callouts after pending notification records are committed. */
public without sharing class OrgMonitorNotificationQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer MAX_ATTEMPTS = 3;
    private final List<Id> notificationIds;

    public OrgMonitorNotificationQueueable(List<Id> notificationIds) {
        this.notificationIds = new List<Id>();
        if (notificationIds != null) this.notificationIds.addAll(notificationIds);
    }

    public void execute(QueueableContext context) {
        if (notificationIds.isEmpty()) return;
        List<Governance_Notification__c> rows = [
            SELECT Id, Provider__c, Status__c, Title__c, Message__c, Content_Format__c,
                   Fallback_Text__c,
                   Destination_Id__c, Team_Id__c, Attempt_Count__c
            FROM Governance_Notification__c
            WHERE Id IN :notificationIds AND Status__c IN ('Pending', 'Retry Scheduled')
            ORDER BY CreatedDate ASC
            LIMIT 100
        ];

        List<Id> retryIds = new List<Id>();
        for (Governance_Notification__c row : rows) {
            row.Status__c = 'Sending';
            row.Attempt_Count__c = (row.Attempt_Count__c == null ? 0 : row.Attempt_Count__c) + 1;
            try {
                CollaborationNotificationService.DeliveryResponse response;
                if (row.Provider__c == 'Slack') {
                    response = row.Content_Format__c == 'SLACK_BLOCKS'
                        ? CollaborationNotificationService.sendSlackBlocks(
                            row.Destination_Id__c, row.Fallback_Text__c, row.Message__c)
                        : CollaborationNotificationService.sendSlackMessage(
                            row.Destination_Id__c, row.Title__c, row.Message__c);
                } else if (row.Provider__c == 'Microsoft Teams') {
                    response = row.Content_Format__c == 'TEAMS_HTML'
                        ? CollaborationNotificationService.sendMicrosoftHtml(
                            row.Team_Id__c, row.Destination_Id__c, row.Message__c)
                        : CollaborationNotificationService.sendMicrosoftMessage(
                            row.Team_Id__c, row.Destination_Id__c, row.Title__c, row.Message__c);
                } else {
                    throw new PermanentDeliveryException('Unsupported notification provider.');
                }
                row.Status__c = 'Sent';
                row.Provider_Message_Id__c = response == null ? null : response.providerMessageId;
                row.Delivered_At__c = System.now();
                row.Error_Message__c = null;
                row.Next_Attempt__c = null;
            } catch (Exception error) {
                classifyFailure(row, error, retryIds);
            }
        }
        if (!rows.isEmpty()) Database.update(rows, false);
        if (!retryIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new OrgMonitorNotificationQueueable(retryIds), 5);
        }
    }

    private static void classifyFailure(Governance_Notification__c row, Exception error,
            List<Id> retryIds) {
        String message = sanitize(error == null ? null : error.getMessage());
        String lower = message.toLowerCase();
        row.Error_Message__c = message;

        if (lower.contains('authorization has expired') || lower.contains('authorization_required')) {
            row.Status__c = 'Reconnection Required';
        } else if (lower.contains('invite') || lower.contains('denied')
                || lower.contains('could not find') || lower.contains('channel')) {
            row.Status__c = 'Action Required';
        } else if (row.Attempt_Count__c < MAX_ATTEMPTS
                && (lower.contains('http 429') || lower.contains('http 5')
                    || lower.contains('timeout') || lower.contains('timed out'))) {
            row.Status__c = 'Retry Scheduled';
            row.Next_Attempt__c = System.now().addMinutes(5);
            retryIds.add(row.Id);
        } else {
            row.Status__c = 'Failed';
        }
    }

    private static String sanitize(String value) {
        if (String.isBlank(value)) return 'Provider delivery failed.';
        String cleaned = value.replaceAll('[\r\n\t]+', ' ').trim();
        return cleaned.left(Math.min(cleaned.length(), 1000));
    }

    private class PermanentDeliveryException extends Exception {}
}