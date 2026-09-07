@IsTest(SeeAllData=false)
private class DeploymentWindowServiceTest {
    @TestSetup static void setupData() {
        DeploymentWindowService.bypassBusinessPermission = true;
        User managerUser = new User(
            Alias = 'dwtest', Email = 'deployment.window@example.com',
            EmailEncodingKey = 'UTF-8', LastName = 'Deployment Window Manager',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'Australia/Sydney',
            Username = 'deployment.window.' + System.now().getTime() + '@example.com'
        );
        insert managerUser;
        PermissionSet manager = [SELECT Id FROM PermissionSet
            WHERE Name = 'Org_Monitor_Deployment_Window_Manager' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = managerUser.Id, PermissionSetId = manager.Id);
        System.runAs(managerUser) {
            upsert new ChangeLogRuntime__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Enable_Deployment_Window_Approval__c = true,
                Deployment_User_Id__c = UserInfo.getUserId()
            );
            Datetime nowValue = System.now();
            insert new List<Deployment_Window__c>{
                window(nowValue.addHours(-1), nowValue.addHours(2), 'Active', 'REL-100', 'Production'),
                window(nowValue.addDays(1), nowValue.addDays(1).addHours(2), 'Draft', 'REL-200', 'Sandbox'),
                window(nowValue.addDays(-2), nowValue.addDays(-2).addHours(2), 'Closed', 'REL-OLD', 'Full-Copy')
            };
        }
    }

    @IsTest static void listsCurrentUpcomingAndPastWithSummary() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        Test.startTest();
        DeploymentWindowService.ListResult current = DeploymentWindowService.listWindows('CURRENT', 1, 25);
        DeploymentWindowService.ListResult past = DeploymentWindowService.listWindows('PAST', 1, 25);
        Test.stopTest();
        System.assertEquals(2, current.totalCount);
        System.assertEquals(1, past.totalCount);
        System.assertNotEquals(null, current.currentWindow);
        System.assertEquals('Active', current.currentWindow.status);
        System.assertEquals('REL-OLD', past.records[0].ticketReference);
        System.assert(String.isNotBlank(current.capabilities.timeZone));
        }
    }

    @IsTest static void createsAndEditsUsingExplicitAcceptedFields() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        DeploymentWindowService.SaveRequest request = validRequest();
        request.releaseRunsheetUrl = 'https://example.com/releases/REL-300';
        Test.startTest();
        Id recordId = DeploymentWindowService.saveWindow(request);
        Test.stopTest();
        Deployment_Window__c created = [SELECT Status__c, Environment__c, Ticket_Reference__c,
            Release_Runsheet_URL__c, Requested_By__c FROM Deployment_Window__c WHERE Id = :recordId];
        System.assertEquals('Draft', created.Status__c);
        System.assertEquals('Production', created.Environment__c, 'The existing environment default remains compatible.');
        System.assertEquals('https://example.com/releases/REL-300', created.Release_Runsheet_URL__c);
        System.assertEquals(UserInfo.getUserId(), created.Requested_By__c);
        System.assertEquals(1, [SELECT COUNT() FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :recordId]);

        request.recordId = recordId; request.ticketReference = 'REL-301'; request.releaseRunsheetUrl = null;
        request.authorisedUsers[0].recordId = [SELECT Id FROM Authorised_Deployment_User__c
            WHERE Deployment_Window__c = :recordId LIMIT 1].Id;
        DeploymentWindowService.saveWindow(request);
        created = [SELECT Ticket_Reference__c, Release_Runsheet_URL__c FROM Deployment_Window__c WHERE Id = :recordId];
        System.assertEquals('REL-301', created.Ticket_Reference__c);
        System.assertEquals(null, created.Release_Runsheet_URL__c);
        }
    }

    @IsTest static void validatesDuplicatesRolesAndMandatoryUsers() {
        System.runAs(managerUser()) {
            DeploymentWindowService.bypassBusinessPermission = true;
            DeploymentWindowService.SaveRequest request = validRequest(); request.authorisedUsers.clear();
            assertSaveRejected(request);
            request = validRequest();
            DeploymentWindowService.AuthorisedUserInput duplicate = authorisedUser(UserInfo.getUserId(), 'Developer');
            request.authorisedUsers.add(duplicate); assertSaveRejected(request);
            request = validRequest(); request.authorisedUsers[0].deploymentRole = 'Arbitrary Role'; assertSaveRejected(request);
        }
    }

    @IsTest static void editsRolesAndRemovesUsersWithoutRecreatingUnchangedRows() {
        System.runAs(managerUser()) {
            DeploymentWindowService.bypassBusinessPermission = true;
            User otherUser = [SELECT Id FROM User WHERE Id != :UserInfo.getUserId() AND IsActive = true LIMIT 1];
            DeploymentWindowService.SaveRequest request = validRequest();
            request.authorisedUsers.add(authorisedUser(otherUser.Id, 'Administrator'));
            Id windowId = DeploymentWindowService.saveWindow(request);
            List<Authorised_Deployment_User__c> beforeRows = [SELECT Id, User__c, Deployment_Role__c FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :windowId];
            Map<Id, Id> idsByUser = new Map<Id, Id>(); for (Authorised_Deployment_User__c row : beforeRows) idsByUser.put(row.User__c, row.Id);
            request.recordId = windowId; request.authorisedUsers.clear();
            DeploymentWindowService.AuthorisedUserInput retained = authorisedUser(otherUser.Id, 'Release Manager');
            retained.recordId = idsByUser.get(otherUser.Id); request.authorisedUsers.add(retained);
            DeploymentWindowService.saveWindow(request);
            Authorised_Deployment_User__c remaining = [SELECT Id, User__c, Deployment_Role__c FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :windowId];
            System.assertEquals(idsByUser.get(otherUser.Id), remaining.Id, 'The unchanged child identity must be preserved.');
            System.assertEquals('Release Manager', remaining.Deployment_Role__c);
            System.assertEquals(1, [SELECT COUNT() FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :windowId]);
        }
    }

    @IsTest static void fallsBackToConfiguredUsersWithoutBackfillingUntilSave() {
        System.runAs(managerUser()) {
            DeploymentWindowService.bypassBusinessPermission = true;
            Deployment_Window__c legacy = window(System.now().addDays(4), System.now().addDays(4).addHours(1), 'Draft', 'REL-LEGACY', 'Production'); insert legacy;
            DeploymentWindowService.WindowDto dto = DeploymentWindowService.getWindow(legacy.Id);
            System.assertEquals(1, dto.authorisedUsers.size());
            System.assertEquals('CI/CD User', dto.authorisedUsers[0].deploymentRole);
            System.assertEquals(0, [SELECT COUNT() FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :legacy.Id]);
            DeploymentWindowService.SaveRequest request = validRequest(); request.recordId = legacy.Id;
            DeploymentWindowService.saveWindow(request);
            System.assertEquals(1, [SELECT COUNT() FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :legacy.Id]);
        }
    }

    @IsTest static void rollsBackParentAndChildrenTogether() {
        System.runAs(managerUser()) {
            DeploymentWindowService.bypassBusinessPermission = true;
            Integer windowsBefore = [SELECT COUNT() FROM Deployment_Window__c];
            DeploymentWindowService.forceChildDmlFailure = true;
            assertSaveRejected(validRequest());
            DeploymentWindowService.forceChildDmlFailure = false;
            System.assertEquals(windowsBefore, [SELECT COUNT() FROM Deployment_Window__c]);
        }
    }

    @IsTest static void preservesExistingCicdDeploymentUserConfiguration() {
        System.runAs(managerUser()) {
            DeploymentWindowService.bypassBusinessPermission = true;
            String configuredIds = ChangeLogRuntime__c.getOrgDefaults().Deployment_User_Id__c;
            DeploymentWindowService.saveWindow(validRequest());
            System.assertEquals(configuredIds, ChangeLogRuntime__c.getOrgDefaults().Deployment_User_Id__c,
                'Deployment Window CRUD must not alter the existing configuration consumed by current processing.');
        }
    }

    @IsTest static void rejectsMissingOrInvalidSchedules() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        DeploymentWindowService.SaveRequest request = validRequest(); request.startDateTime = null;
        assertSaveRejected(request);
        request = validRequest(); request.endDateTime = null; assertSaveRejected(request);
        request = validRequest(); request.endDateTime = request.startDateTime; assertSaveRejected(request);
        request = validRequest(); request.endDateTime = request.startDateTime.addMinutes(-1); assertSaveRejected(request);
        }
    }

    @IsTest static void acceptsOnlySecureRunsheetUrls() {
        System.runAs(managerUser()) {
        System.assert(DeploymentWindowService.isValidHttps('https://example.com/runbook'));
        System.assert(!DeploymentWindowService.isValidHttps('http://example.com/runbook'));
        System.assert(!DeploymentWindowService.isValidHttps('javascript:alert(1)'));
        System.assert(!DeploymentWindowService.isValidHttps('not a url'));
        DeploymentWindowService.bypassBusinessPermission = true;
        for (String unsafeValue : new List<String>{ 'http://example.com', 'javascript:alert(1)', 'not a url' }) {
            DeploymentWindowService.SaveRequest request = validRequest(); request.releaseRunsheetUrl = unsafeValue;
            assertSaveRejected(request);
        }
        }
    }

    @IsTest static void performsOnlySupportedStatusTransitions() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        ChangeLogRuntime__c settings = ChangeLogRuntime__c.getOrgDefaults();
        settings.Enable_Deployment_Window_Approval__c = false;
        update settings;
        Deployment_Window__c draft = window(System.now(), System.now().addHours(1), 'Draft', 'REL-ACT', 'Production'); insert draft;
        DeploymentWindowService.WindowDto active = DeploymentWindowService.transition(draft.Id, 'ACTIVATE');
        System.assertEquals('Active', active.status);
        DeploymentWindowService.WindowDto closed = DeploymentWindowService.transition(draft.Id, 'CLOSE');
        System.assertEquals('Closed', closed.status);
        assertTransitionRejected(draft.Id, 'CANCEL');

        Deployment_Window__c rejected = window(System.now(), System.now().addHours(1), 'Rejected', 'REL-CAN', 'Production'); insert rejected;
        System.assertEquals('Cancelled', DeploymentWindowService.transition(rejected.Id, 'CANCEL').status);
        assertTransitionRejected(rejected.Id, 'UNKNOWN');
        }
    }

    @IsTest static void validatesIdsAndBusinessPermission() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        Boolean wrongIdRejected = false;
        try { DeploymentWindowService.getWindow(UserInfo.getUserId()); }
        catch (AuraHandledException expected) { wrongIdRejected = true; }
        System.assert(wrongIdRejected);

        DeploymentWindowService.bypassBusinessPermission = false;
        if (!DeploymentWindowService.getCapabilities().canView) {
            Boolean permissionRejected = false;
            try { DeploymentWindowService.listWindows('CURRENT', 1, 25); }
            catch (AuraHandledException expected) { permissionRejected = true; }
            System.assert(permissionRejected, 'A user without a business permission must be rejected.');
        }
        }
    }

    @IsTest static void remainsCompatibleWithExistingBatchSelector() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.DeploymentWindowSchema schema =
            new AuditTrailMetadataService().getDeploymentWindowSchema();
        List<SObject> activeWindows = new AuditTrailSelector().getActiveDeploymentWindows(schema);
        System.assertEquals(3, activeWindows.size(), 'The existing resolver continues to qualify approval-enabled records regardless of stored Status.');
        System.assertEquals('start_date_time__c', schema.startField.toLowerCase());
        System.assertEquals('end_date_time__c', schema.endField.toLowerCase());
        System.assertEquals('enable_approval_process__c', schema.statusField.toLowerCase());
        System.assertEquals(true, schema.isStatusBoolean);
        Deployment_Window__c legacy = [SELECT Environment__c, Release_Runsheet_URL__c
            FROM Deployment_Window__c WHERE Status__c = 'Active' LIMIT 1];
        System.assertNotEquals(null, legacy.Environment__c);
        System.assertEquals(null, legacy.Release_Runsheet_URL__c, 'Existing records with a blank runsheet remain valid.');
        }
    }

    @IsTest static void controllerReturnsFriendlyErrors() {
        System.runAs(managerUser()) {
        DeploymentWindowService.bypassBusinessPermission = true;
        DeploymentWindowService.SaveRequest request = validRequest(); request.releaseRunsheetUrl = 'ftp://example.com';
        Boolean rejected = false;
        try { DeploymentWindowController.saveWindow(request); }
        catch (AuraHandledException expected) { rejected = true; }
        System.assert(rejected);
        System.assertNotEquals(null, DeploymentWindowController.getCapabilities());
        System.assertNotEquals(null, DeploymentWindowController.searchUsers('adm'));
        System.assertNotEquals(null, DeploymentWindowController.listWindows('CURRENT', 1, 25));
        DeploymentWindowService.SaveRequest valid = validRequest();
        Id recordId = DeploymentWindowController.saveWindow(valid);
        System.assertEquals(recordId, DeploymentWindowController.getWindow(recordId).id);
        System.assertEquals('Cancelled', DeploymentWindowController.transition(recordId, 'CANCEL').status);
        DeploymentWindowService.SaveRequest workspaceRequest = validRequest();
        workspaceRequest.startDateTime = null; workspaceRequest.endDateTime = null;
        Id workspaceId = DeploymentWindowController.saveWindowFromWorkspace(
            JSON.serialize(workspaceRequest),
            '2026-09-10T09:30:00.000Z', '2026-09-10T10:30:00.000Z'
        );
        Deployment_Window__c workspaceRecord = [SELECT Ticket_Reference__c, Description__c
            FROM Deployment_Window__c WHERE Id = :workspaceId];
        System.assertEquals('REL-300', workspaceRecord.Ticket_Reference__c);
        System.assertEquals('Production release', workspaceRecord.Description__c);
        }
    }

    @IsTest static void capturesApproverWhenApprovalActivatesWindow() {
        System.runAs(managerUser()) {
            Deployment_Window__c pendingApproval = window(
                System.now(), System.now().addHours(2), 'Draft', 'REL-APPROVER', 'Production'
            );
            insert pendingApproval;
            pendingApproval.Status__c = 'Active';
            update pendingApproval;
            Deployment_Window__c approved = [SELECT Approved_By__c FROM Deployment_Window__c
                WHERE Id = :pendingApproval.Id];
            System.assertEquals(UserInfo.getUserId(), approved.Approved_By__c);
        }
    }

    private static Deployment_Window__c window(Datetime starts, Datetime ends, String status, String ticket, String environment) {
        return new Deployment_Window__c(Start_Date_Time__c = starts, End_Date_Time__c = ends,
            Status__c = status, Ticket_Reference__c = ticket, Environment__c = environment,
            Requested_By__c = UserInfo.getUserId());
    }
    private static User managerUser() {
        return [SELECT Id FROM User WHERE Alias = 'dwtest' LIMIT 1];
    }
    private static DeploymentWindowService.SaveRequest validRequest() {
        DeploymentWindowService.SaveRequest request = new DeploymentWindowService.SaveRequest();
        request.startDateTime = System.now().addDays(3); request.endDateTime = System.now().addDays(3).addHours(2);
        request.ticketReference = 'REL-300'; request.description = 'Production release';
        request.authorisedUsers = new List<DeploymentWindowService.AuthorisedUserInput>{ authorisedUser(UserInfo.getUserId(), 'CI/CD User') };
        return request;
    }
    private static DeploymentWindowService.AuthorisedUserInput authorisedUser(Id userId, String role) {
        DeploymentWindowService.AuthorisedUserInput value = new DeploymentWindowService.AuthorisedUserInput();
        value.userId = userId; value.deploymentRole = role; return value;
    }
    private static void assertSaveRejected(DeploymentWindowService.SaveRequest request) {
        Boolean rejected = false; try { DeploymentWindowService.saveWindow(request); } catch (AuraHandledException expected) { rejected = true; }
        System.assert(rejected, 'Save should have been rejected.');
    }
    private static void assertTransitionRejected(Id recordId, String action) {
        Boolean rejected = false; try { DeploymentWindowService.transition(recordId, action); } catch (AuraHandledException expected) { rejected = true; }
        System.assert(rejected, 'Transition should have been rejected.');
    }
}