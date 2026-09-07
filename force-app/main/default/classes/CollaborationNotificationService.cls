public with sharing class CollaborationNotificationService {
    @TestVisible private static final String SLACK = 'callout:OrgMonitor_Slack';
    @TestVisible private static final String GRAPH = 'callout:OrgMonitor_MicrosoftGraph';
    private static final Integer TIMEOUT_MS = 20000;
    private static final String TEST_TEXT = 'Org Monitor connection successful\n\nThis channel is now connected to Org Monitor for Salesforce setup-change notifications.';

    public class Destination {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        public Destination(String id, String name, String type) {
            this.id = id; this.name = name; this.type = type;
        }
    }
    public class Identity {
        @AuraEnabled public Boolean connected;
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String accountName;
    }
    public class DeliveryResponse {
        public String providerMessageId;
        public DeliveryResponse(String providerMessageId) {
            this.providerMessageId = providerMessageId;
        }
    }

    public static Identity verifySlack() {
        Map<String, Object> body = slack('GET', '/api/auth.test', null);
        Identity result = new Identity();
        result.connected = true;
        result.id = stringValue(body.get('team_id'));
        result.name = stringValue(body.get('team'));
        result.accountName = stringValue(body.get('user'));
        return result;
    }

    public static List<Destination> getSlackChannels(Boolean includePrivateChannels) {
        List<Destination> result = new List<Destination>();
        String cursor;
        Integer pages = 0;
        do {
            String types = includePrivateChannels == true ? 'public_channel,private_channel' : 'public_channel';
            String path = '/api/conversations.list?exclude_archived=true&limit=200&types=' + types;
            if (String.isNotBlank(cursor)) path += '&cursor=' + EncodingUtil.urlEncode(cursor, 'UTF-8');
            Map<String, Object> body = slack('GET', path, null);
            for (Object item : listValue(body.get('channels'))) {
                Map<String, Object> channel = (Map<String, Object>) item;
                if (channel.get('is_archived') != true) {
                    result.add(new Destination(stringValue(channel.get('id')), stringValue(channel.get('name')), 'channel'));
                }
            }
            Map<String, Object> metadata = mapValue(body.get('response_metadata'));
            cursor = stringValue(metadata.get('next_cursor'));
            pages++;
        } while (String.isNotBlank(cursor) && pages < 25);
        return result;
    }

    public static void sendSlackTest(String channelId) {
        requireId(channelId, 'Slack channel');
        slack('POST', '/api/chat.postMessage', new Map<String, Object>{ 'channel' => channelId, 'text' => TEST_TEXT });
    }

    /** Sends a completed, plain-text notification through the packaged credential. */
    public static DeliveryResponse sendSlackMessage(String channelId, String title, String message) {
        requireId(channelId, 'Slack channel');
        Map<String, Object> body = slack('POST', '/api/chat.postMessage', new Map<String, Object>{
            'channel' => channelId,
            'text' => notificationText(title, message)
        });
        return new DeliveryResponse(stringValue(body.get('ts')));
    }

    /** Sends renderer-produced Block Kit with a concise accessible fallback. */
    public static DeliveryResponse sendSlackBlocks(String channelId, String fallbackText,
            String blocksJson) {
        requireId(channelId, 'Slack channel');
        Object parsed;
        try { parsed = JSON.deserializeUntyped(blocksJson); }
        catch (Exception error) { throw safeError('Slack notification blocks are invalid.'); }
        if (!(parsed instanceof List<Object>)) throw safeError('Slack notification blocks are invalid.');
        Map<String, Object> body = slack('POST', '/api/chat.postMessage', new Map<String, Object>{
            'channel' => channelId, 'text' => fallbackText, 'unfurl_links' => false,
            'unfurl_media' => false, 'blocks' => parsed
        });
        return new DeliveryResponse(stringValue(body.get('ts')));
    }

    public static Identity verifyMicrosoft() {
        Map<String, Object> me = graph('GET', '/v1.0/me?$select=id,displayName,userPrincipalName', null);
        Identity result = new Identity();
        result.connected = true;
        result.id = stringValue(me.get('id'));
        result.name = stringValue(me.get('displayName'));
        result.accountName = stringValue(me.get('userPrincipalName'));
        return result;
    }

    public static List<Destination> getMicrosoftTeams() {
        return graphCollection('/v1.0/me/joinedTeams?$select=id,displayName', 'team');
    }

    public static List<Destination> getMicrosoftChannels(String teamId) {
        requireId(teamId, 'Team');
        return graphCollection('/v1.0/teams/' + encodeSegment(teamId) + '/channels?$select=id,displayName,membershipType', 'channel');
    }

    public static void sendMicrosoftTest(String teamId, String channelId) {
        requireId(teamId, 'Team'); requireId(channelId, 'Teams channel');
        graph('POST', '/v1.0/teams/' + encodeSegment(teamId) + '/channels/' + encodeSegment(channelId) + '/messages',
            new Map<String, Object>{ 'body' => new Map<String, Object>{ 'contentType' => 'text', 'content' => TEST_TEXT } });
    }

    /** Sends text, never caller-supplied HTML, through the packaged Graph credential. */
    public static DeliveryResponse sendMicrosoftMessage(
            String teamId, String channelId, String title, String message) {
        requireId(teamId, 'Team'); requireId(channelId, 'Teams channel');
        Map<String, Object> body = graph(
            'POST',
            '/v1.0/teams/' + encodeSegment(teamId) + '/channels/' + encodeSegment(channelId) + '/messages',
            new Map<String, Object>{
                'body' => new Map<String, Object>{
                    'contentType' => 'text',
                    'content' => notificationText(title, message)
                }
            }
        );
        return new DeliveryResponse(stringValue(body.get('id')));
    }

    /** Sends renderer-produced, escaped, Teams-compatible HTML. */
    public static DeliveryResponse sendMicrosoftHtml(
            String teamId, String channelId, String htmlContent) {
        requireId(teamId, 'Team'); requireId(channelId, 'Teams channel');
        if (String.isBlank(htmlContent)) throw safeError('Teams notification content is required.');
        Map<String, Object> body = graph('POST', '/v1.0/teams/' + encodeSegment(teamId)
            + '/channels/' + encodeSegment(channelId) + '/messages', new Map<String, Object>{
                'body' => new Map<String, Object>{ 'contentType' => 'html', 'content' => htmlContent }
            });
        return new DeliveryResponse(stringValue(body.get('id')));
    }

    private static List<Destination> graphCollection(String initialPath, String type) {
        List<Destination> result = new List<Destination>();
        String path = initialPath;
        Integer pages = 0;
        while (String.isNotBlank(path) && pages < 25) {
            Map<String, Object> body = graph('GET', path, null);
            for (Object item : listValue(body.get('value'))) {
                Map<String, Object> row = (Map<String, Object>) item;
                result.add(new Destination(stringValue(row.get('id')), stringValue(row.get('displayName')), type));
            }
            String nextLink = stringValue(body.get('@odata.nextLink'));
            if (String.isBlank(nextLink)) path = null;
            else if (nextLink.startsWith('https://graph.microsoft.com')) path = nextLink.substring('https://graph.microsoft.com'.length());
            else throw safeError('Microsoft returned an invalid pagination URL.');
            pages++;
        }
        return result;
    }

    private static String notificationText(String title, String message) {
        if (String.isBlank(message)) throw safeError('Notification message is required.');
        return String.isBlank(title) ? message : title.trim() + '\n\n' + message;
    }

    private static Map<String, Object> slack(String method, String path, Object payload) {
        HttpResponse response = send(SLACK + path, method, payload);
        Map<String, Object> body = deserializeMap(response.getBody());
        if (response.getStatusCode() < 200 || response.getStatusCode() > 299) throw httpError('Slack', response);
        if (body.get('ok') != true) {
            String code = stringValue(body.get('error'));
            if (code == 'not_in_channel') throw safeError('Invite the OrgMonitor Slack app to the selected channel, then send the test message again. In Slack, open the channel and use /invite @OrgMonitor.');
            if (code == 'channel_not_found') throw safeError('Slack could not access the selected channel. Confirm the channel still exists and invite @OrgMonitor.');
            if (code == 'missing_scope') throw safeError('The Slack authorization is missing a required scope. Confirm the app scopes, then reconnect Slack.');
            throw safeError('Slack request failed: ' + sanitize(code));
        }
        return body;
    }

    private static Map<String, Object> graph(String method, String path, Object payload) {
        HttpResponse response = send(GRAPH + path, method, payload);
        Map<String, Object> body = String.isBlank(response.getBody()) ? new Map<String, Object>() : deserializeMap(response.getBody());
        if (response.getStatusCode() < 200 || response.getStatusCode() > 299) throw httpError('Microsoft Graph', response);
        return body;
    }

    private static HttpResponse send(String endpoint, String method, Object payload) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint); request.setMethod(method); request.setTimeout(TIMEOUT_MS);
        request.setHeader('Accept', 'application/json');
        if (payload != null) { request.setHeader('Content-Type', 'application/json'); request.setBody(JSON.serialize(payload)); }
        return new Http().send(request);
    }

    private static AuraHandledException httpError(String provider, HttpResponse response) {
        Integer status = response.getStatusCode();
        String suffix = status == 429 ? ' Try again after ' + sanitize(response.getHeader('Retry-After')) + ' seconds.' : '';
        if (status == 401) return safeError(provider + ' authorization has expired. Reconnect the account.');
        if (status == 403) return safeError(provider + ' denied the request. Check consent, scopes, and channel membership.');
        if (status == 404) return safeError(provider + ' could not find the selected destination.');
        return safeError(provider + ' request failed (HTTP ' + status + ').' + suffix);
    }
    private static AuraHandledException safeError(String message) { return new AuraHandledException(message); }
    private static String sanitize(String value) { return String.isBlank(value) ? 'unknown error' : value.replaceAll('[^a-zA-Z0-9_ .-]', '').left(160); }
    private static String encodeSegment(String value) { return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20'); }
    private static void requireId(String value, String label) { if (String.isBlank(value) || value.length() > 512) throw safeError(label + ' is required.'); }
    private static String stringValue(Object value) { return value == null ? null : String.valueOf(value); }
    private static Map<String, Object> deserializeMap(String value) { try { return (Map<String, Object>) JSON.deserializeUntyped(value); } catch (Exception e) { throw safeError('The provider returned an invalid response.'); } }
    private static Map<String, Object> mapValue(Object value) { return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>(); }
    private static List<Object> listValue(Object value) { return value instanceof List<Object> ? (List<Object>) value : new List<Object>(); }
}