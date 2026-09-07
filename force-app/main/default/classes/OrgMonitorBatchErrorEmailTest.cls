@IsTest
private class OrgMonitorBatchErrorEmailTest {
    @IsTest static void buildsBrandedSafeConfigurationError() {
        Messaging.SingleEmailMessage message = OrgMonitorBatchErrorNotificationService.build(
            'Configuration validation',
            'Microsoft Teams is enabled but its tested destination is incomplete.\nsecret-line',
            null, false, UserInfo.getUserId());
        System.assertEquals('[Org Monitor] Change monitoring encountered an error',
            message.getSubject());
        System.assert(message.getPlainTextBody().contains(
            'Org Monitor encountered an error while working.'));
        System.assert(message.getPlainTextBody().contains('watermark was not advanced'));
        System.assert(message.getPlainTextBody().contains('Open Org Monitor Setup'));
        System.assert(!message.getPlainTextBody().contains('\nsecret-line'));
        System.assert(message.getHtmlBody().contains(
            'Org Monitor encountered an error while working'));
    }

    @IsTest static void sendsWithoutThrowing() {
        Test.startTest();
        OrgMonitorBatchErrorNotificationService.send(
            'Persistence', 'A change record could not be saved.', 'OM-TEST', false);
        System.assertEquals(1, Limits.getEmailInvocations());
        Test.stopTest();
    }
}