/**
 * SlackNotificationService
 * Posts a pre-built message (table summary + link) to Slack via an
 * Incoming Webhook, referenced through a Named Credential so the
 * webhook URL itself is never exposed in code or logs.
 *
 * Setup required: Setup > Named Credentials > New, with the URL set to
 * your Slack Incoming Webhook URL and Authentication = No Authentication
 * Required. Name it to match NAMED_CREDENTIAL below.
 */
public class SlackNotificationService {

    private static final String NAMED_CREDENTIAL = 'callout:Slack_Bot_OAuth';

    public static void postNonComplianceAlert(String messageText) {
        if (String.isBlank(messageText)) return;

        Map<String, Object> payload = new Map<String, Object>{ 'text' => messageText };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug('Slack notification failed: ' + res.getStatusCode() + ' ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('Slack notification error: ' + e.getMessage());
        }
    }
}