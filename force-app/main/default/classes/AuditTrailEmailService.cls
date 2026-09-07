/**
 * AuditTrailEmailService
 * Sends a single consolidated violation notification email covering all
 * non-compliant Change_Log__c records in the batch. Every affected user
 * is added to the To line, their managers (plus any configured additional
 * CC addresses) are added to Cc. Only the first 10 records are shown in
 * the email body; if there are more, a "See More" link to a list view
 * is included instead of truncating silently.
 */
public class AuditTrailEmailService {

    /*private static final Integer MAX_RECORDS_IN_EMAIL = 10;

    // Must match the Developer Name of a List View on Change_Log__c
    // filtered to Non_Compliant__c = true. Keep in sync with the
    // default on ChangeLogNonComplianceAlert's listViewFilterName attribute.
    private static final String NON_COMPLIANT_LIST_VIEW_API_NAME = 'Non_Compliant_Changes';

    public static void sendViolationEmails(
        List<Change_Log__c>  violations,
        List<SetupAuditTrail> auditRows,
        Change_Log_Config__mdt config
    ) {
        Map<String, SetupAuditTrail> rowMap = new Map<String, SetupAuditTrail>();
        for (SetupAuditTrail r : auditRows) rowMap.put(r.Id, r);

        // Filter down to eligible, not-yet-notified, high/critical violations
        // and collect the recipient + manager addresses along the way.
        List<Change_Log__c> eligibleLogs = new List<Change_Log__c>();
        Set<String> toAddressSet = new Set<String>();
        Set<String> ccAddressSet = new Set<String>();

        for (Change_Log__c log : violations) {
            if (log.Email_Sent__c) continue; // deduplicate

            SetupAuditTrail row = rowMap.get(log.External_Id__c);
            if (row == null || String.isBlank(row.CreatedBy.Email)) continue;

            String severity = AuditTrailSeverityService.getSeverity(row.Action);
            //if (severity == 'MEDIUM' || severity == 'LOW') continue;

            eligibleLogs.add(log);
            toAddressSet.add(row.CreatedBy.Email);
            if (String.isNotBlank(row.CreatedBy.Manager?.Email)) {
                ccAddressSet.add(row.CreatedBy.Manager.Email);
            }
        }

        if (eligibleLogs.isEmpty()) return;

        if (String.isNotBlank(config?.Additional_Email_CC__c)) {
            for (String addr : config.Additional_Email_CC__c.split(',')) {
                if (String.isNotBlank(addr)) ccAddressSet.add(addr.trim());
            }
        }

        // Post to Slack alongside the email, independent of its outcome
        SlackNotificationService.postNonComplianceAlert(
            new List<String>(toAddressSet), eligibleLogs.size(), buildListViewUrl()
        );
        postToNativeSlackFlow(eligibleLogs.size(), new List<String>(toAddressSet));

        // Cap what's shown in the email body; everyone still gets notified
        // and can reach the rest via the list view link.
        Integer shownCount = Math.min(MAX_RECORDS_IN_EMAIL, eligibleLogs.size());
        List<Change_Log__c> shownLogs = new List<Change_Log__c>();
        for (Integer i = 0; i < shownCount; i++) {
            shownLogs.add(eligibleLogs[i]);
        }
        Integer remainingCount = eligibleLogs.size() - shownCount;

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>(toAddressSet));
        if (!ccAddressSet.isEmpty()) mail.setCcAddresses(new List<String>(ccAddressSet));
        mail.setSubject('[ACTION REQUIRED] ' + eligibleLogs.size()
            + ' Non-Compliant Salesforce Change' + (eligibleLogs.size() > 1 ? 's' : '') + ' Detected');
        mail.setHtmlBody(buildEmailBody(shownLogs, remainingCount));
        mail.setSaveAsActivity(false);

        Messaging.SendEmailResult[] results = Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ mail }, false
        );

        if (results[0].isSuccess()) {
            List<Change_Log__c> toUpdate = new List<Change_Log__c>();
            for (Change_Log__c log : eligibleLogs) {
                toUpdate.add(new Change_Log__c(Id = log.Id, Email_Sent__c = true));
            }
            update toUpdate;
        } else {
            for (Database.Error err : results[0].getErrors()) {
                System.debug('Consolidated violation email failed: ' + err.getMessage());
            }
        }
    }

    /**
     * Renders the ChangeLogEmailPage (which hosts the
     * ChangeLogNonComplianceAlert component) for the capped set of
     * records to show, plus the remaining count.
     *
    private static String buildEmailBody(List<Change_Log__c> shownLogs, Integer remainingCount) {
        List<Id> logIds = new List<Id>();
        for (Change_Log__c log : shownLogs) logIds.add(log.Id);

        PageReference pr = Page.ChangeLogEmailPage;
        pr.getParameters().put('recordIds', String.join(logIds, ','));
        pr.getParameters().put('remainingCount', String.valueOf(remainingCount));
        pr.setRedirect(false);

        return pr.getContent().toString();
    }

    private static String buildListViewUrl() {
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        return orgUrl + '/lightning/o/Change_Log__c/list?filterName='
            + EncodingUtil.urlEncode(NON_COMPLIANT_LIST_VIEW_API_NAME, 'UTF-8');
    }

    /**
     * Triggers the Autolaunched Flow ("Slack Message to Org Monitor") that
     * posts to Slack via the native Salesforce-Slack connection.
     *
    private static void postToNativeSlackFlow(Integer totalViolations, List<String> userEmails) {
        List<String> sortedEmails = new List<String>(userEmails);
        sortedEmails.sort();

        String messageText = ':rotating_light: ' + totalViolations
            + ' Non-Compliant Salesforce Change' + (totalViolations > 1 ? 's' : '') + ' Detected\n'
            + 'Affected user(s): ' + String.join(sortedEmails, ', ');

        Map<String, Object> inputs = new Map<String, Object>{ 'messageText' => messageText };

        try {
            Flow.Interview.Slack_Message_to_Org_Monitor flowInterview =
                new Flow.Interview.Slack_Message_to_Org_Monitor(inputs);
            flowInterview.start();
        } catch (Exception e) {
            System.debug('Native Slack Flow invocation failed: ' + e.getMessage());
        }
    } */
}