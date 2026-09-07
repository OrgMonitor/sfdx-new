/** Sends a safe, human-readable administrator email for change-monitoring failures. */
public inherited sharing class OrgMonitorBatchErrorNotificationService {
    public static void send(String phase, String detail, String correlationId,
            Boolean watermarkAdvanced) {
        try {
            Messaging.SingleEmailMessage message = build(
                phase, detail, correlationId, watermarkAdvanced, UserInfo.getUserId());
            Messaging.SendEmailResult[] results = Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ message }, false);
            if (results.isEmpty() || !results[0].isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    '[Org Monitor] The administrator error email could not be sent.');
            }
        } catch (Exception emailError) {
            System.debug(LoggingLevel.ERROR,
                '[Org Monitor] The administrator error email could not be prepared: '
                + sanitize(emailError.getMessage()));
        }
    }

    @TestVisible
    private static Messaging.SingleEmailMessage build(String phase, String detail,
            String correlationId, Boolean watermarkAdvanced, Id recipientId) {
        String safePhase = sanitize(String.isBlank(phase) ? 'Change monitoring' : phase);
        String safeDetail = sanitize(detail);
        String safeReference = sanitize(String.isBlank(correlationId)
            ? 'Not available (the run stopped before a reference was created)' : correlationId);
        String impact = watermarkAdvanced == true
            ? 'Detected changes remain saved and the monitoring watermark was advanced. '
                + 'Org Monitor will not recreate those change records.'
            : 'The monitoring watermark was not advanced. Org Monitor will safely retry this '
                + 'time period after the problem is corrected.';
        String action = suggestedAction(safeDetail);

        String plain = 'Org Monitor encountered an error while working.\n\n'
            + 'Stage: ' + safePhase + '\n'
            + 'What happened: ' + safeDetail + '\n\n'
            + 'Processing impact: ' + impact + '\n\n'
            + 'Recommended action: ' + action + '\n\n'
            + 'Run reference: ' + safeReference + '\n'
            + 'No credentials or provider secrets are included in this message.';
        String html = '<h2>Org Monitor encountered an error while working</h2>'
            + '<p>Org Monitor could not complete part of the Salesforce change-monitoring process.</p>'
            + '<table cellpadding="6" cellspacing="0" border="0">'
            + '<tr><td><strong>Stage</strong></td><td>' + escapeHtml(safePhase) + '</td></tr>'
            + '<tr><td><strong>What happened</strong></td><td>' + escapeHtml(safeDetail) + '</td></tr>'
            + '<tr><td><strong>Processing impact</strong></td><td>' + escapeHtml(impact) + '</td></tr>'
            + '<tr><td><strong>Recommended action</strong></td><td>' + escapeHtml(action) + '</td></tr>'
            + '<tr><td><strong>Run reference</strong></td><td>' + escapeHtml(safeReference) + '</td></tr>'
            + '</table><p><small>No credentials or provider secrets are included in this message.</small></p>';

        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setTargetObjectId(recipientId);
        message.setTreatTargetObjectAsRecipient(true);
        message.setSaveAsActivity(false);
        message.setSubject('[Org Monitor] Change monitoring encountered an error');
        message.setPlainTextBody(plain);
        message.setHtmlBody(html);
        return message;
    }

    private static String suggestedAction(String detail) {
        String lower = detail.toLowerCase();
        if (lower.contains('teams') || lower.contains('slack') || lower.contains('destination')) {
            return 'Open Org Monitor Setup, confirm the enabled provider and destination, send a '
                + 'successful test message, and then allow the next scheduled run to retry.';
        }
        if (lower.contains('rule') || lower.contains('regex') || lower.contains('severity')
                || lower.contains('category')) {
            return 'Review the Org Monitor classification configuration, correct the reported '
                + 'validation issue, and then allow the next scheduled run to retry.';
        }
        if (lower.contains('another org monitor') || lower.contains('overlap')) {
            return 'No action is normally required. The active run will continue, and the next '
                + 'five-minute schedule will check for remaining changes.';
        }
        return 'Review Org Monitor App Setup and the referenced stage, correct the reported issue, '
            + 'and then allow the next scheduled run to retry.';
    }

    private static String sanitize(String value) {
        if (String.isBlank(value)) return 'An unexpected error occurred.';
        String cleaned = value.replaceAll('[\\r\\n\\t]+', ' ').trim();
        return cleaned.left(Math.min(cleaned.length(), 1000));
    }
    private static String escapeHtml(String value) {
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;').replace('\'', '&#39;');
    }
}