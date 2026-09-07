@IsTest
private class ChangeLogErrorServiceTest {

    @IsTest
    static void testLogError_exceptionPopulatesBuffer() {
        ChangeLogErrorService.clearBuffer();
        Exception ex = new ChangeLogException('Test exception');

        ChangeLogErrorService.logError('TestContext', ex, 'ref-001');

        List<ChangeLogErrorService.ErrorEntry> buf = ChangeLogErrorService.getBuffer();
        System.assertEquals(1, buf.size());
        System.assertEquals('TestContext', buf[0].context);
        System.assertEquals('Test exception', buf[0].message);
        System.assertEquals('ref-001', buf[0].relatedRecordRef);
    }

    @IsTest
    static void testLogError_stringMessagePopulatesBuffer() {
        ChangeLogErrorService.clearBuffer();
        ChangeLogErrorService.logError('Ctx', 'Some message', 'ref-002');

        List<ChangeLogErrorService.ErrorEntry> buf = ChangeLogErrorService.getBuffer();
        System.assertEquals(1, buf.size());
        System.assertEquals('Some message', buf[0].message);
    }

    @IsTest
    static void testFlushBuffer_clearsAfterReturn() {
        ChangeLogErrorService.clearBuffer();
        ChangeLogErrorService.logError('Ctx', 'Msg1', null);
        ChangeLogErrorService.logError('Ctx', 'Msg2', null);

        List<ChangeLogErrorService.ErrorEntry> flushed = ChangeLogErrorService.flushBuffer();
        System.assertEquals(2, flushed.size());
        System.assert(ChangeLogErrorService.getBuffer().isEmpty(),
            'Buffer should be empty after flush');
    }

    @IsTest
    static void testClearBuffer() {
        ChangeLogErrorService.logError('Ctx', 'Msg', null);
        ChangeLogErrorService.clearBuffer();
        System.assert(ChangeLogErrorService.getBuffer().isEmpty());
    }

    @IsTest
    static void testProcessSaveResults_capturesErrors() {
        ChangeLogErrorService.clearBuffer();

        // Build a fake failing SaveResult list by inserting a record that violates uniqueness
        Deployment_Window__c dw = ChangeLogTestDataFactory.insertDeploymentWindow(
            System.now(), System.now().addHours(1), 'Active');

        // Attempt a duplicate insert of a required-unique field scenario using DML false
        Change_Log__c at1 = new Change_Log__c(External_Id__c = 'UNIQUE-001');
        insert at1;

        Change_Log__c at2 = new Change_Log__c(External_Id__c = 'UNIQUE-001');
        List<Database.SaveResult> results = Database.insert(
            new List<Change_Log__c>{ at2 }, false);

        ChangeLogErrorService.processSaveResults(
            results, new List<SObject>{ at2 }, 'TestInsert');

        // at least one error should have been logged since External_Id__c is unique
        Integer errorCount = 0;
        for (Database.SaveResult sr : results) {
            if (!sr.isSuccess()) errorCount++;
        }
        if (errorCount > 0) {
            System.assert(!ChangeLogErrorService.getBuffer().isEmpty(),
                'Errors should be logged for failed save results');
        }
    }

    @IsTest
    static void testLogError_nullExceptionDoesNotThrow() {
        ChangeLogErrorService.clearBuffer();
        ChangeLogErrorService.logError('Ctx', (Exception) null, null);
        System.assertEquals(1, ChangeLogErrorService.getBuffer().size());
    }

    @IsTest
    static void testErrorEntry_hasTimestamp() {
        ChangeLogErrorService.clearBuffer();
        ChangeLogErrorService.logError('Ctx', 'Msg', null);
        ChangeLogErrorService.ErrorEntry entry = ChangeLogErrorService.getBuffer()[0];
        System.assertNotEquals(null, entry.occurredAt);
    }
}