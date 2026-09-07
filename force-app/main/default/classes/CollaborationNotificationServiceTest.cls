@IsTest
private class CollaborationNotificationServiceTest {
    private static String lastRequestBody;
    private class Mock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            lastRequestBody = request.getBody();
            HttpResponse response = new HttpResponse(); response.setStatusCode(200);
            if (request.getEndpoint().contains('auth.test')) response.setBody('{"ok":true,"team_id":"T1","team":"Acme","user":"org-monitor"}');
            else if (request.getEndpoint().contains('conversations.list')) response.setBody('{"ok":true,"channels":[{"id":"C1","name":"governance","is_archived":false}],"response_metadata":{"next_cursor":""}}');
            else if (request.getEndpoint().contains('/me?')) response.setBody('{"id":"U1","displayName":"Admin","userPrincipalName":"admin@example.com"}');
            else if (request.getEndpoint().contains('joinedTeams')) response.setBody('{"value":[{"id":"TEAM1","displayName":"Governance"}]}');
            else if (request.getEndpoint().contains('/channels?')) response.setBody('{"value":[{"id":"CHAN1","displayName":"General"}]}');
            else response.setBody(request.getEndpoint().contains('Slack') ? '{"ok":true}' : '{}');
            return response;
        }
    }
    @IsTest static void verifiesAndDiscoversSlack() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        System.assertEquals('T1', CollaborationNotificationService.verifySlack().id);
        System.assertEquals('C1', CollaborationNotificationService.getSlackChannels(false)[0].id);
        CollaborationNotificationService.sendSlackTest('C1');
    }
    @IsTest static void verifiesAndDiscoversMicrosoft() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        System.assertEquals('U1', CollaborationNotificationService.verifyMicrosoft().id);
        System.assertEquals('TEAM1', CollaborationNotificationService.getMicrosoftTeams()[0].id);
        System.assertEquals('CHAN1', CollaborationNotificationService.getMicrosoftChannels('TEAM1')[0].id);
        CollaborationNotificationService.sendMicrosoftTest('TEAM1', 'CHAN1');
    }
    private class ErrorMock implements HttpCalloutMock {
        Integer code; String body; ErrorMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest request) { HttpResponse r = new HttpResponse(); r.setStatusCode(code); r.setBody(body); r.setHeader('Retry-After', '30'); return r; }
    }
    @IsTest static void handlesSlackLogicalError() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock(200, '{"ok":false,"error":"missing_scope"}'));
        Boolean thrown = false;
        try { CollaborationNotificationService.verifySlack(); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, 'Slack logical errors must be surfaced.');
    }
    @IsTest static void explainsSlackChannelMembership() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock(200, '{"ok":false,"error":"not_in_channel"}'));
        Boolean thrown = false;
        try {
            CollaborationNotificationService.sendSlackTest('C1');
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'The Slack membership error must be safely surfaced.');
    }
    @IsTest static void handlesGraphRateLimit() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock(429, '{"error":{"code":"TooManyRequests"}}'));
        Boolean thrown = false;
        try { CollaborationNotificationService.verifyMicrosoft(); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, 'Graph rate limits must be surfaced.');
    }
    @IsTest static void sendsSlackBlockKitWithAccessibleFallback() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        CollaborationNotificationService.sendSlackBlocks('C1', 'Accessible summary',
            '[{"type":"header","text":{"type":"plain_text","text":"Org Monitor"}}]');
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(lastRequestBody);
        System.assertEquals('Accessible summary', payload.get('text'));
        System.assertEquals(false, payload.get('unfurl_links'));
        System.assertEquals(1, ((List<Object>) payload.get('blocks')).size());
    }
    @IsTest static void sendsTeamsAsExplicitHtml() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        CollaborationNotificationService.sendMicrosoftHtml(
            'T1', 'C1', '<b>Org Monitor</b><br>Detected changes');
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(lastRequestBody);
        Map<String, Object> body = (Map<String, Object>) payload.get('body');
        System.assertEquals('html', body.get('contentType'));
        System.assert(String.valueOf(body.get('content')).contains('<br>'));
    }
}