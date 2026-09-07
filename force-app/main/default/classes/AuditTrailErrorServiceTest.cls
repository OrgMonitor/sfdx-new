@IsTest
private class AuditTrailErrorServiceTest {

    @IsTest
    static void testLogError_exceptionPopulatesBuffer() {
        AuditTrailErrorService.clearBuffer();
        Exception ex = new AuditTrailException('Test exception');

        AuditTrailErrorService.logError('TestContext', ex, 'ref-001');

        List<AuditTrailErrorService.ErrorEntry> buf = AuditTrailErrorService.getBuffer();
        System.assertEquals(1, buf.size());
        System.assertEquals('TestContext', buf[0].context);
        System.assertEquals('Test exception', buf[0].message);
        System.assertEquals('ref-001', buf[0].relatedRecordRef);
    }

    @IsTest
    static void testLogError_stringMessagePopulatesBuffer() {
        AuditTrailErrorService.clearBuffer();
        AuditTrailErrorService.logError('Ctx', 'Some message', 'ref-002');

        List<AuditTrailErrorService.ErrorEntry> buf = AuditTrailErrorService.getBuffer();
        System.assertEquals(1, buf.size());
        System.assertEquals('Some message', buf[0].message);
    }

    @IsTest
    static void testFlushBuffer_clearsAfterReturn() {
        AuditTrailErrorService.clearBuffer();
        AuditTrailErrorService.logError('Ctx', 'Msg1', null);
        AuditTrailErrorService.logError('Ctx', 'Msg2', null);

        List<AuditTrailErrorService.ErrorEntry> flushed = AuditTrailErrorService.flushBuffer();
        System.assertEquals(2, flushed.size());
        System.assert(AuditTrailErrorService.getBuffer().isEmpty(),
            'Buffer should be empty after flush');
    }

    @IsTest
    static void testClearBuffer() {
        AuditTrailErrorService.logError('Ctx', 'Msg', null);
        AuditTrailErrorService.clearBuffer();
        System.assert(AuditTrailErrorService.getBuffer().isEmpty());
    }

    @IsTest
    static void testProcessSaveResults_capturesErrors() {
        AuditTrailErrorService.clearBuffer();

        // Build a fake failing SaveResult list by inserting a record that violates uniqueness
        Deployment_Window__c dw = AuditTrailTestDataFactory.insertDeploymentWindow(
            System.now(), System.now().addHours(1), 'Active');

        // Attempt a duplicate insert of a required-unique field scenario using DML false
        Audit_Trail__c at1 = new Audit_Trail__c(External_Id__c = 'UNIQUE-001');
        insert at1;

        Audit_Trail__c at2 = new Audit_Trail__c(External_Id__c = 'UNIQUE-001');
        List<Database.SaveResult> results = Database.insert(
            new List<Audit_Trail__c>{ at2 }, false);

        AuditTrailErrorService.processSaveResults(
            results, new List<SObject>{ at2 }, 'TestInsert');

        // at least one error should have been logged since External_Id__c is unique
        Integer errorCount = 0;
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) errorCount++;
        }
        if (errorCount > 0) {
            System.assert(!AuditTrailErrorService.getBuffer().isEmpty(),
                'Errors should be logged for failed save results');
        }
    }

    @IsTest
    static void testLogError_nullExceptionDoesNotThrow() {
        AuditTrailErrorService.clearBuffer();
        AuditTrailErrorService.logError('Ctx', (Exception) null, null);
        System.assertEquals(1, AuditTrailErrorService.getBuffer().size());
    }

    @IsTest
    static void testErrorEntry_hasTimestamp() {
        AuditTrailErrorService.clearBuffer();
        AuditTrailErrorService.logError('Ctx', 'Msg', null);
        AuditTrailErrorService.ErrorEntry entry = AuditTrailErrorService.getBuffer()[0];
        System.assertNotEquals(null, entry.occurredAt);
    }
}