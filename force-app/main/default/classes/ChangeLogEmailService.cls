/**
 * ChangeLogEmailService
 * Sends a single consolidated violation notification email covering all
 * non-compliant Change_Log__c records in the batch. Every affected user
 * is added to the To line, their managers (plus any configured additional
 * CC addresses) are added to Cc. Only the first 10 records are shown in
 * the email body (and the Slack summary); if there are more, a "See More"
 * link to a list view is included instead of truncating silently.
 */
public class ChangeLogEmailService {

    private static final Integer MAX_RECORDS_SHOWN = 10;

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

            String severity = ChangeLogSeverityService.getSeverity(row.Action);
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

        // Cap what's shown (both in the email body and the Slack summary);
        // everyone still gets notified and can reach the rest via the link.
        Integer shownCount = Math.min(MAX_RECORDS_SHOWN, eligibleLogs.size());
        List<Change_Log__c> shownLogs = new List<Change_Log__c>();
        for (Integer i = 0; i < shownCount; i++) {
            shownLogs.add(eligibleLogs[i]);
        }
        Integer remainingCount = eligibleLogs.size() - shownCount;
        String listViewUrl = buildListViewUrl();

        // Build a simple (non-tabular) summary and post it to both Slack paths
        String slackMessageText = buildSlackSummaryText(eligibleLogs, listViewUrl, rowMap);
        SlackNotificationService.postNonComplianceAlert(slackMessageText);
        postToNativeSlackFlow(slackMessageText);

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
     */
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
     * Builds a simple (non-tabular) Slack summary: total count, a
     * breakdown by severity, and the list of users whose changes were
     * flagged, plus a link to the full list view.
     */
    private static String buildSlackSummaryText(
        List<Change_Log__c> eligibleLogs,
        String listViewUrl,
        Map<String, SetupAuditTrail> rowMap
    ) {
        Integer totalViolations = eligibleLogs.size();

        // Count by severity
        Map<String, Integer> countBySeverity = new Map<String, Integer>();
        // Collect distinct users as "Name (email)", de-duplicated
        Map<String, String> userByEmail = new Map<String, String>();

        for (Change_Log__c log : eligibleLogs) {
            String severity = String.isNotBlank(log.Severity__c) ? log.Severity__c : 'Unknown';
            countBySeverity.put(severity, (countBySeverity.containsKey(severity) ? countBySeverity.get(severity) : 0) + 1);

            SetupAuditTrail row = rowMap.get(log.External_Id__c);
            if (row != null && String.isNotBlank(row.CreatedBy.Email)) {
                userByEmail.put(row.CreatedBy.Email, row.CreatedBy.Name);
            }
        }

        String message = ':rotating_light: *' + totalViolations + ' Non-Compliant Salesforce Change'
            + (totalViolations > 1 ? 's' : '') + ' Detected*\n\n';

        message += '*Severity breakdown:*\n';
        List<String> severityOrder = new List<String>{ 'Critical', 'High', 'Medium', 'Low', 'Unknown' };
        for (String sev : severityOrder) {
            if (countBySeverity.containsKey(sev)) {
                message += '\u2022 ' + sev + ': ' + countBySeverity.get(sev) + '\n';
            }
        }
        // Catch any severity values not in the expected list above
        for (String sev : countBySeverity.keySet()) {
            if (!severityOrder.contains(sev)) {
                message += '\u2022 ' + sev + ': ' + countBySeverity.get(sev) + '\n';
            }
        }

        List<String> userLines = new List<String>();
        List<String> sortedEmails = new List<String>(userByEmail.keySet());
        sortedEmails.sort();
        for (String email : sortedEmails) {
            String name = userByEmail.get(email);
            userLines.add(String.isNotBlank(name) ? name + ' (' + email + ')' : email);
        }
        message += '\n*User(s) who made these changes:*\n\u2022 ' + String.join(userLines, '\n\u2022 ');

        if (String.isNotBlank(listViewUrl)) {
            message += '\n\n<' + listViewUrl + '|View all non-compliant records>';
        }

        return message;
    }

    /**
     * Triggers the Autolaunched Flow ("Slack Message to Org Monitor") that
     * posts to Slack via the native Salesforce-Slack connection.
     */
    private static void postToNativeSlackFlow(String messageText) {
        Map<String, Object> inputs = new Map<String, Object>{ 'messageText' => messageText };

        try {
            Flow.Interview.Slack_Message_to_Org_Monitor flowInterview =
                new Flow.Interview.Slack_Message_to_Org_Monitor(inputs);
            flowInterview.start();
        } catch (Exception e) {
            System.debug('Native Slack Flow invocation failed: ' + e.getMessage());
        }
    }
}