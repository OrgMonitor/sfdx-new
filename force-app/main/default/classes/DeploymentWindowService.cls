/** Business and security layer for the Deployment Windows workspace. */
public with sharing class DeploymentWindowService {
    public static final String VIEW_CURRENT = 'CURRENT';
    public static final String VIEW_PAST = 'PAST';
    private static final Integer DEFAULT_PAGE_SIZE = 25;
    private static final Integer MAX_PAGE_SIZE = 50;
    private static final Set<String> EDITABLE_STATUSES = new Set<String>{ 'Draft', 'Rejected', 'Active' };
    private static final Set<String> DEPLOYMENT_ROLES = new Set<String>{
        'CI/CD User', 'Administrator', 'Developer', 'Release Manager', 'Data Migration', 'Other'
    };
    @TestVisible private static Boolean bypassBusinessPermission = false;
    @TestVisible private static Boolean forceChildDmlFailure = false;

    public class Capabilities {
        @AuraEnabled public Boolean canView;
        @AuraEnabled public Boolean canManage;
        @AuraEnabled public Boolean canApprove;
        @AuraEnabled public String timeZone;
        @AuraEnabled public List<AuthorisedUserDto> defaultAuthorisedUsers = new List<AuthorisedUserDto>();
    }
    public class WindowDto {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Datetime startDateTime;
        @AuraEnabled public Datetime endDateTime;
        @AuraEnabled public String status;
        @AuraEnabled public String storedStatus;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String requestedByName;
        @AuraEnabled public Id requestedById;
        @AuraEnabled public String approvedByName;
        @AuraEnabled public Id approvedById;
        @AuraEnabled public String ticketReference;
        @AuraEnabled public String description;
        @AuraEnabled public String releaseRunsheetUrl;
        @AuraEnabled public Boolean approvalEnabled;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public Boolean canActivate;
        @AuraEnabled public Boolean canSubmit;
        @AuraEnabled public Boolean canClose;
        @AuraEnabled public Boolean canCancel;
        @AuraEnabled public Boolean canApproveRequest;
        @AuraEnabled public Boolean canRejectRequest;
        @AuraEnabled public List<AuthorisedUserDto> authorisedUsers = new List<AuthorisedUserDto>();
    }
    public class ListResult {
        @AuraEnabled public List<WindowDto> records = new List<WindowDto>();
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Boolean hasNext;
        @AuraEnabled public WindowDto currentWindow;
        @AuraEnabled public WindowDto nextWindow;
        @AuraEnabled public Capabilities capabilities;
    }
    public class SaveRequest {
        @AuraEnabled public Id recordId;
        @AuraEnabled public Datetime startDateTime;
        @AuraEnabled public Datetime endDateTime;
        @AuraEnabled public String ticketReference;
        @AuraEnabled public String description;
        @AuraEnabled public String releaseRunsheetUrl;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public Id requestedById;
        @AuraEnabled public List<AuthorisedUserInput> authorisedUsers;
    }
    public class AuthorisedUserInput {
        @AuraEnabled public Id recordId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String deploymentRole;
        @AuraEnabled public String notes;
    }
    public class AuthorisedUserDto {
        @AuraEnabled public Id recordId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String deploymentRole;
        @AuraEnabled public String notes;
    }
    public class UserOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String label;
        public UserOption(User userRecord) { id = userRecord.Id; label = userRecord.Name; }
    }

    public static Capabilities getCapabilities() {
        Capabilities result = new Capabilities();
        result.canManage = bypassBusinessPermission || FeatureManagement.checkPermission('Manage_Deployment_Windows');
        result.canApprove = bypassBusinessPermission || FeatureManagement.checkPermission('Approve_Deployment_Windows');
        result.canView = result.canManage || result.canApprove
            || FeatureManagement.checkPermission('View_Deployment_Windows');
        result.timeZone = UserInfo.getTimeZone().getID();
        if (result.canManage) result.defaultAuthorisedUsers = configuredDeploymentUsers();
        return result;
    }

    public static ListResult listWindows(String viewName, Integer pageNumber, Integer pageSize) {
        requireView(); requireReadAccess();
        String normalizedView = normalizeView(viewName);
        Integer safePage = pageNumber == null || pageNumber < 1 ? 1 : Math.min(pageNumber, 80);
        Integer safeSize = pageSize == null ? DEFAULT_PAGE_SIZE : Math.max(1, Math.min(pageSize, MAX_PAGE_SIZE));
        Integer rowOffset = (safePage - 1) * safeSize;
        Datetime nowValue = System.now();
        List<Deployment_Window__c> rows;
        Integer total;
        if (normalizedView == VIEW_CURRENT) {
            rows = [
                SELECT Id, Name, Start_Date_Time__c, End_Date_Time__c, Status__c,
                       OwnerId, Owner.Name, Requested_By__c, Requested_By__r.Name,
                       Approved_By__c, Approved_By__r.Name, Ticket_Reference__c,
                       Description__c, Release_Runsheet_URL__c, Enable_Approval_Process__c
                FROM Deployment_Window__c
                WHERE End_Date_Time__c >= :nowValue
                  AND Status__c NOT IN ('Closed', 'Cancelled', 'Rejected')
                WITH USER_MODE
                ORDER BY Start_Date_Time__c ASC NULLS LAST, Id ASC
                LIMIT :safeSize OFFSET :rowOffset
            ];
            total = [SELECT COUNT() FROM Deployment_Window__c
                WHERE End_Date_Time__c >= :nowValue
                  AND Status__c NOT IN ('Closed', 'Cancelled', 'Rejected') WITH USER_MODE];
        } else {
            rows = [
                SELECT Id, Name, Start_Date_Time__c, End_Date_Time__c, Status__c,
                       OwnerId, Owner.Name, Requested_By__c, Requested_By__r.Name,
                       Approved_By__c, Approved_By__r.Name, Ticket_Reference__c,
                       Description__c, Release_Runsheet_URL__c, Enable_Approval_Process__c
                FROM Deployment_Window__c
                WHERE End_Date_Time__c < :nowValue
                   OR Status__c IN ('Closed', 'Cancelled', 'Rejected')
                WITH USER_MODE
                ORDER BY End_Date_Time__c DESC NULLS LAST, Id DESC
                LIMIT :safeSize OFFSET :rowOffset
            ];
            total = [SELECT COUNT() FROM Deployment_Window__c
                WHERE End_Date_Time__c < :nowValue
                   OR Status__c IN ('Closed', 'Cancelled', 'Rejected') WITH USER_MODE];
        }
        Set<Id> pendingIds = pendingApprovalIds(rows);
        Capabilities capabilities = getCapabilities();
        ListResult result = new ListResult();
        result.pageNumber = safePage; result.pageSize = safeSize; result.totalCount = total;
        result.hasNext = rowOffset + rows.size() < total; result.capabilities = capabilities;
        for (Deployment_Window__c row : rows) result.records.add(toDto(row, pendingIds, capabilities));
        addScheduleSummary(result, nowValue, capabilities);
        return result;
    }

    public static WindowDto getWindow(Id recordId) {
        requireView(); requireReadAccess(); validateWindowId(recordId);
        List<Deployment_Window__c> rows = [
            SELECT Id, Name, Start_Date_Time__c, End_Date_Time__c, Status__c,
                   OwnerId, Owner.Name, Requested_By__c, Requested_By__r.Name,
                   Approved_By__c, Approved_By__r.Name, Ticket_Reference__c,
                   Description__c, Release_Runsheet_URL__c, Enable_Approval_Process__c
            FROM Deployment_Window__c WHERE Id = :recordId WITH USER_MODE LIMIT 1
        ];
        if (rows.isEmpty()) throw friendly('Deployment window was not found or is not accessible.');
        WindowDto result = toDto(rows[0], pendingApprovalIds(rows), getCapabilities());
        result.authorisedUsers = loadAuthorisedUsers(recordId);
        if (result.authorisedUsers.isEmpty()) result.authorisedUsers = configuredDeploymentUsers();
        return result;
    }

    public static Id saveWindow(SaveRequest request) {
        requireManage();
        if (request == null) throw friendly('Deployment window details are required.');
        validateSchedule(request.startDateTime, request.endDateTime);
        String runsheet = validateRunsheet(request.releaseRunsheetUrl);
        if (String.isBlank(request.ticketReference)) throw friendly('Ticket Reference is required.');
        if (String.isBlank(request.description)) throw friendly('Description / Purpose is required.');
        validateText(request.ticketReference, 255, 'Ticket Reference');
        validateText(request.description, 32000, 'Description');
        validateUserId(request.ownerId, 'Owner'); validateUserId(request.requestedById, 'Requested By');
        List<AuthorisedUserInput> submittedUsers = validateAuthorisedUsers(request.authorisedUsers);

        Savepoint transactionStart = Database.setSavepoint();
        try {

        if (request.recordId == null) {
            requireCreateAccess();
            Deployment_Window__c row = new Deployment_Window__c();
            row.Start_Date_Time__c = request.startDateTime; row.End_Date_Time__c = request.endDateTime;
            row.Ticket_Reference__c = blankToNull(request.ticketReference);
            row.Description__c = blankToNull(request.description);
            row.Release_Runsheet_URL__c = runsheet;
            row.Requested_By__c = request.requestedById == null ? UserInfo.getUserId() : request.requestedById;
            if (request.ownerId != null) row.OwnerId = request.ownerId;
            row.Status__c = 'Draft';
            Database.insert(row, AccessLevel.USER_MODE);
            syncAuthorisedUsers(row.Id, submittedUsers);
            return row.Id;
        }

        validateWindowId(request.recordId); requireUpdateAccess();
        List<Deployment_Window__c> existingRows = [
            SELECT Id, Status__c FROM Deployment_Window__c
            WHERE Id = :request.recordId WITH USER_MODE LIMIT 1
        ];
        if (existingRows.isEmpty()) throw friendly('Deployment window was not found or is not editable.');
        Deployment_Window__c row = existingRows[0];
        if (!EDITABLE_STATUSES.contains(row.Status__c))
            throw friendly('This deployment window cannot be edited in its current status.');
        row.Start_Date_Time__c = request.startDateTime; row.End_Date_Time__c = request.endDateTime;
        row.Ticket_Reference__c = blankToNull(request.ticketReference);
        row.Description__c = blankToNull(request.description);
        row.Release_Runsheet_URL__c = runsheet;
        if (request.ownerId != null) row.OwnerId = request.ownerId;
        if (request.requestedById != null) row.Requested_By__c = request.requestedById;
        Database.update(row, AccessLevel.USER_MODE);
        syncAuthorisedUsers(row.Id, submittedUsers);
        return row.Id;
        } catch (Exception error) {
            Database.rollback(transactionStart);
            throw error;
        }
    }

    public static WindowDto transition(Id recordId, String actionName) {
        String action = String.isBlank(actionName) ? '' : actionName.trim().toUpperCase();
        Boolean approvalDecision = action == 'APPROVE' || action == 'REJECT';
        if (approvalDecision) requireApprove();
        else { requireManage(); requireUpdateAccess(); }
        validateWindowId(recordId);
        if (approvalDecision) {
            List<ProcessInstanceWorkitem> workItems = [
                SELECT Id FROM ProcessInstanceWorkitem
                WHERE ProcessInstance.TargetObjectId = :recordId
                ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (workItems.isEmpty()) throw friendly('No pending approval request is available for this deployment window.');
            Approval.ProcessWorkitemRequest decision = new Approval.ProcessWorkitemRequest();
            decision.setWorkitemId(workItems[0].Id);
            decision.setAction(action == 'APPROVE' ? 'Approve' : 'Reject');
            decision.setComments((action == 'APPROVE' ? 'Approved' : 'Rejected') + ' from Org Monitor Deployment Windows.');
            Approval.ProcessResult decisionResult = Approval.process(decision);
            if (!decisionResult.isSuccess()) throw friendly('Salesforce could not complete the approval decision.');
            return getWindow(recordId);
        }
        List<Deployment_Window__c> rows = [SELECT Id, Status__c, Enable_Approval_Process__c
            FROM Deployment_Window__c WHERE Id = :recordId WITH USER_MODE LIMIT 1 FOR UPDATE];
        if (rows.isEmpty()) throw friendly('Deployment window was not found or is not editable.');
        Deployment_Window__c row = rows[0];
        if (action == 'ACTIVATE') {
            if (row.Enable_Approval_Process__c == true || !new Set<String>{'Draft','Rejected'}.contains(row.Status__c))
                throw friendly('This deployment window cannot be activated directly.');
            row.Status__c = 'Active'; Database.update(row, AccessLevel.USER_MODE);
        } else if (action == 'SUBMIT') {
            if (row.Enable_Approval_Process__c != true || !new Set<String>{'Draft','Rejected'}.contains(row.Status__c))
                throw friendly('This deployment window cannot be submitted for approval.');
            Approval.ProcessSubmitRequest submit = new Approval.ProcessSubmitRequest();
            submit.setObjectId(row.Id); submit.setComments('Submitted from Org Monitor Deployment Windows.');
            Approval.ProcessResult approvalResult = Approval.process(submit);
            if (!approvalResult.isSuccess()) throw friendly('Salesforce could not submit this deployment window for approval.');
        } else if (action == 'CLOSE') {
            if (row.Status__c != 'Active') throw friendly('Only an active deployment window can be closed.');
            row.Status__c = 'Closed'; Database.update(row, AccessLevel.USER_MODE);
        } else if (action == 'CANCEL') {
            if (!new Set<String>{'Draft','Rejected','Active'}.contains(row.Status__c))
                throw friendly('This deployment window cannot be cancelled in its current status.');
            row.Status__c = 'Cancelled'; Database.update(row, AccessLevel.USER_MODE);
        } else throw friendly('Unsupported deployment window action.');
        return getWindow(recordId);
    }

    public static List<UserOption> searchUsers(String searchTerm) {
        requireManage();
        if (String.isBlank(searchTerm)) return new List<UserOption>();
        String term = '%' + searchTerm.trim().left(80) + '%';
        List<UserOption> result = new List<UserOption>();
        for (User userRecord : [SELECT Id, Name FROM User
            WHERE IsActive = true AND (Name LIKE :term OR Email LIKE :term OR Username LIKE :term)
            WITH USER_MODE ORDER BY Name, Id LIMIT 10]) result.add(new UserOption(userRecord));
        return result;
    }

    private static List<AuthorisedUserInput> validateAuthorisedUsers(List<AuthorisedUserInput> values) {
        if (values == null || values.isEmpty()) throw friendly('Add at least one Authorised Deployment User.');
        Set<Id> userIds = new Set<Id>();
        for (AuthorisedUserInput value : values) {
            if (value == null || value.userId == null || value.userId.getSObjectType() != User.SObjectType)
                throw friendly('Every authorised deployment user must be an active Salesforce user.');
            if (!userIds.add(value.userId)) throw friendly('The same authorised deployment user cannot be added more than once.');
            if (!DEPLOYMENT_ROLES.contains(value.deploymentRole)) throw friendly('Select a valid deployment role for every authorised user.');
            validateText(value.notes, 1000, 'Authorised user notes');
            if (value.recordId != null && value.recordId.getSObjectType() != Authorised_Deployment_User__c.SObjectType)
                throw friendly('An authorised deployment user record ID is invalid.');
        }
        Set<Id> activeIds = new Map<Id, User>([SELECT Id FROM User WHERE Id IN :userIds AND IsActive = true WITH USER_MODE]).keySet();
        if (activeIds.size() != userIds.size()) throw friendly('Every authorised deployment user must be active and accessible.');
        return values;
    }

    private static void syncAuthorisedUsers(Id windowId, List<AuthorisedUserInput> submitted) {
        requireAuthorisedUserWriteAccess();
        Map<Id, Authorised_Deployment_User__c> existingById = new Map<Id, Authorised_Deployment_User__c>([
            SELECT Id, User__c, Deployment_Role__c, Notes__c
            FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :windowId WITH USER_MODE
        ]);
        List<Authorised_Deployment_User__c> inserts = new List<Authorised_Deployment_User__c>();
        List<Authorised_Deployment_User__c> updates = new List<Authorised_Deployment_User__c>();
        Set<Id> retainedIds = new Set<Id>();
        Set<Id> existingUserIds = new Set<Id>();
        for (Authorised_Deployment_User__c existing : existingById.values()) existingUserIds.add(existing.User__c);
        for (AuthorisedUserInput value : submitted) {
            Authorised_Deployment_User__c existing = value.recordId == null ? null : existingById.get(value.recordId);
            if (value.recordId != null && existing == null) throw friendly('An authorised user record does not belong to this Deployment Window.');
            if (existing == null) {
                if (existingUserIds.contains(value.userId)) throw friendly('The same authorised deployment user cannot be added more than once.');
                inserts.add(new Authorised_Deployment_User__c(
                    Deployment_Window__c = windowId, User__c = value.userId,
                    Deployment_Role__c = value.deploymentRole, Notes__c = blankToNull(value.notes)
                ));
            } else {
                retainedIds.add(existing.Id);
                if (existing.User__c != value.userId) throw friendly('The user on an existing authorisation cannot be replaced; remove it and add another user.');
                if (existing.Deployment_Role__c != value.deploymentRole || existing.Notes__c != blankToNull(value.notes)) {
                    existing.Deployment_Role__c = value.deploymentRole;
                    existing.Notes__c = blankToNull(value.notes);
                    updates.add(existing);
                }
            }
        }
        List<Authorised_Deployment_User__c> deletes = new List<Authorised_Deployment_User__c>();
        for (Authorised_Deployment_User__c existing : existingById.values()) if (!retainedIds.contains(existing.Id)) deletes.add(existing);
        if (!inserts.isEmpty()) Database.insert(inserts, AccessLevel.USER_MODE);
        if (!updates.isEmpty()) Database.update(updates, AccessLevel.USER_MODE);
        if (!deletes.isEmpty()) Database.delete(deletes, AccessLevel.USER_MODE);
        if (forceChildDmlFailure) throw friendly('Forced authorised-user save failure.');
    }

    private static List<AuthorisedUserDto> loadAuthorisedUsers(Id windowId) {
        requireAuthorisedUserReadAccess();
        List<AuthorisedUserDto> result = new List<AuthorisedUserDto>();
        for (Authorised_Deployment_User__c row : [
            SELECT Id, User__c, User__r.Name, Deployment_Role__c, Notes__c
            FROM Authorised_Deployment_User__c WHERE Deployment_Window__c = :windowId
            WITH USER_MODE ORDER BY User__r.Name, Id
        ]) result.add(toAuthorisedUserDto(row));
        return result;
    }

    private static List<AuthorisedUserDto> configuredDeploymentUsers() {
        List<AuthorisedUserDto> result = new List<AuthorisedUserDto>();
        ChangeLogRuntime__c settings = ChangeLogRuntime__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Deployment_User_Id__c)) return result;
        Set<Id> ids = new Set<Id>();
        for (String token : settings.Deployment_User_Id__c.split(',')) {
            try { Id value = (Id) token.trim(); if (value.getSObjectType() == User.SObjectType) ids.add(value); } catch (Exception ignored) {}
        }
        if (ids.isEmpty()) return result;
        for (User userRecord : [SELECT Id, Name FROM User WHERE Id IN :ids AND IsActive = true WITH USER_MODE ORDER BY Name, Id]) {
            AuthorisedUserDto dto = new AuthorisedUserDto(); dto.userId = userRecord.Id;
            dto.userName = userRecord.Name; dto.deploymentRole = 'CI/CD User'; result.add(dto);
        }
        return result;
    }

    private static AuthorisedUserDto toAuthorisedUserDto(Authorised_Deployment_User__c row) {
        AuthorisedUserDto dto = new AuthorisedUserDto(); dto.recordId = row.Id; dto.userId = row.User__c;
        dto.userName = row.User__r.Name; dto.deploymentRole = row.Deployment_Role__c; dto.notes = row.Notes__c;
        return dto;
    }

    private static void addScheduleSummary(ListResult result, Datetime nowValue, Capabilities capabilities) {
        List<Deployment_Window__c> summaryRows = [
            SELECT Id, Name, Start_Date_Time__c, End_Date_Time__c, Status__c,
                   OwnerId, Owner.Name, Requested_By__c, Requested_By__r.Name,
                   Approved_By__c, Approved_By__r.Name, Ticket_Reference__c,
                   Description__c, Release_Runsheet_URL__c, Enable_Approval_Process__c
            FROM Deployment_Window__c
            WHERE Status__c = 'Active' AND End_Date_Time__c >= :nowValue
            WITH USER_MODE ORDER BY Start_Date_Time__c ASC, Id ASC LIMIT 20
        ];
        Set<Id> pending = new Set<Id>();
        for (Deployment_Window__c row : summaryRows) {
            WindowDto dto = toDto(row, pending, capabilities);
            if (result.currentWindow == null && row.Start_Date_Time__c <= nowValue
                    && row.End_Date_Time__c >= nowValue) result.currentWindow = dto;
            if (result.nextWindow == null && row.Start_Date_Time__c > nowValue) result.nextWindow = dto;
        }
    }

    private static Set<Id> pendingApprovalIds(List<Deployment_Window__c> rows) {
        Set<Id> ids = new Set<Id>(); for (Deployment_Window__c row : rows) ids.add(row.Id);
        Set<Id> pending = new Set<Id>(); if (ids.isEmpty()) return pending;
        for (ProcessInstance process : [SELECT TargetObjectId FROM ProcessInstance
            WHERE TargetObjectId IN :ids AND Status = 'Pending' WITH USER_MODE]) pending.add(process.TargetObjectId);
        return pending;
    }

    private static WindowDto toDto(Deployment_Window__c row, Set<Id> pendingIds, Capabilities caps) {
        WindowDto dto = new WindowDto(); dto.id = row.Id; dto.name = row.Name;
        dto.startDateTime = row.Start_Date_Time__c; dto.endDateTime = row.End_Date_Time__c;
        dto.storedStatus = row.Status__c; dto.status = pendingIds.contains(row.Id) ? 'Submitted for Approval' : row.Status__c;
        dto.ownerId = row.OwnerId; dto.ownerName = row.Owner == null ? null : row.Owner.Name;
        dto.requestedById = row.Requested_By__c; dto.requestedByName = row.Requested_By__r == null ? null : row.Requested_By__r.Name;
        dto.approvedById = row.Approved_By__c; dto.approvedByName = row.Approved_By__r == null ? null : row.Approved_By__r.Name;
        dto.ticketReference = row.Ticket_Reference__c;
        dto.description = row.Description__c == null ? null : row.Description__c.stripHtmlTags();
        dto.releaseRunsheetUrl = isValidHttps(row.Release_Runsheet_URL__c) ? row.Release_Runsheet_URL__c : null;
        dto.approvalEnabled = row.Enable_Approval_Process__c;
        Boolean pending = pendingIds.contains(row.Id); dto.canEdit = caps.canManage && !pending && EDITABLE_STATUSES.contains(row.Status__c);
        dto.canActivate = caps.canManage && !pending && row.Enable_Approval_Process__c != true && new Set<String>{'Draft','Rejected'}.contains(row.Status__c);
        dto.canSubmit = caps.canManage && !pending && row.Enable_Approval_Process__c == true && new Set<String>{'Draft','Rejected'}.contains(row.Status__c);
        dto.canClose = caps.canManage && !pending && row.Status__c == 'Active';
        dto.canCancel = caps.canManage && !pending && new Set<String>{'Draft','Rejected','Active'}.contains(row.Status__c);
        dto.canApproveRequest = caps.canApprove && pending;
        dto.canRejectRequest = caps.canApprove && pending;
        return dto;
    }

    private static void requireView() { if (!getCapabilities().canView) throw friendly('You do not have permission to view deployment windows.'); }
    private static void requireManage() { if (!getCapabilities().canManage) throw friendly('You do not have permission to manage deployment windows.'); }
    private static void requireApprove() { if (!getCapabilities().canApprove) throw friendly('You do not have permission to approve deployment windows.'); }
    private static void requireReadAccess() {
        if (!Deployment_Window__c.SObjectType.getDescribe().isAccessible())
            throw friendly('Deployment Window access is required.');
        requireFieldAccess(readFields(), 'Read access to the Deployment Window fields is required.', 'READ');
    }
    private static void requireCreateAccess() {
        if (!Deployment_Window__c.SObjectType.getDescribe().isCreateable())
            throw friendly('Create access to Deployment Windows is required.');
        requireFieldAccess(writeFields(), 'Create access to the Deployment Window fields is required.', 'CREATE');
    }
    private static void requireUpdateAccess() {
        if (!Deployment_Window__c.SObjectType.getDescribe().isUpdateable())
            throw friendly('Edit access to Deployment Windows is required.');
        requireFieldAccess(writeFields(), 'Edit access to the Deployment Window fields is required.', 'UPDATE');
    }
    private static void requireAuthorisedUserReadAccess() {
        if (!Authorised_Deployment_User__c.SObjectType.getDescribe().isAccessible())
            throw friendly('Authorised Deployment User access is required.');
        requireFieldAccess(authorisedUserFields(), 'Read access to Authorised Deployment User fields is required.', 'READ');
    }
    private static void requireAuthorisedUserWriteAccess() {
        Schema.DescribeSObjectResult description = Authorised_Deployment_User__c.SObjectType.getDescribe();
        if (!description.isAccessible() || !description.isCreateable() || !description.isUpdateable() || !description.isDeletable())
            throw friendly('Create, edit and remove access to Authorised Deployment Users is required.');
        requireFieldAccess(authorisedUserFields(), 'Write access to Authorised Deployment User fields is required.', 'CREATE');
        requireFieldAccess(new List<Schema.SObjectField>{
            Authorised_Deployment_User__c.Deployment_Role__c, Authorised_Deployment_User__c.Notes__c
        }, 'Write access to Authorised Deployment User fields is required.', 'UPDATE');
    }
    private static List<Schema.SObjectField> authorisedUserFields() {
        return new List<Schema.SObjectField>{
            Authorised_Deployment_User__c.Deployment_Window__c, Authorised_Deployment_User__c.User__c,
            Authorised_Deployment_User__c.Deployment_Role__c, Authorised_Deployment_User__c.Notes__c
        };
    }
    private static List<Schema.SObjectField> readFields() {
        return new List<Schema.SObjectField>{
            Deployment_Window__c.Name, Deployment_Window__c.Start_Date_Time__c,
            Deployment_Window__c.End_Date_Time__c, Deployment_Window__c.Status__c,
            Deployment_Window__c.OwnerId, Deployment_Window__c.Requested_By__c,
            Deployment_Window__c.Approved_By__c, Deployment_Window__c.Ticket_Reference__c,
            Deployment_Window__c.Description__c, Deployment_Window__c.Release_Runsheet_URL__c,
            Deployment_Window__c.Enable_Approval_Process__c
        };
    }
    private static List<Schema.SObjectField> writeFields() {
        return new List<Schema.SObjectField>{
            Deployment_Window__c.Start_Date_Time__c, Deployment_Window__c.End_Date_Time__c,
            Deployment_Window__c.Status__c, Deployment_Window__c.OwnerId,
            Deployment_Window__c.Requested_By__c, Deployment_Window__c.Ticket_Reference__c,
            Deployment_Window__c.Description__c, Deployment_Window__c.Release_Runsheet_URL__c
        };
    }
    private static void requireFieldAccess(List<Schema.SObjectField> fields, String message, String operation) {
        for (Schema.SObjectField field : fields) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            Boolean allowed = operation == 'READ' ? describe.isAccessible()
                : operation == 'CREATE' ? describe.isCreateable() : describe.isUpdateable();
            if (!allowed) throw friendly(message);
        }
    }
    private static void validateWindowId(Id value) { if (value == null || value.getSObjectType() != Deployment_Window__c.SObjectType) throw friendly('Enter a valid Deployment Window record ID.'); }
    private static void validateUserId(Id value, String label) { if (value == null) return; if (value.getSObjectType() != User.SObjectType) throw friendly(label + ' must be an active Salesforce user.'); if ([SELECT COUNT() FROM User WHERE Id = :value AND IsActive = true WITH USER_MODE] == 0) throw friendly(label + ' must be an active accessible user.'); }
    private static void validateSchedule(Datetime startValue, Datetime endValue) { if (startValue == null) throw friendly('Start Date/Time is required.'); if (endValue == null) throw friendly('End Date/Time is required.'); if (endValue <= startValue) throw friendly('End Date/Time must be later than Start Date/Time.'); }
    private static void validateText(String value, Integer maxLength, String label) { if (value != null && value.length() > maxLength) throw friendly(label + ' is too long.'); }
    private static String validateRunsheet(String value) { if (String.isBlank(value)) return null; String trimmed = value.trim(); if (trimmed.length() > 255 || !isValidHttps(trimmed)) throw friendly('Release Runsheet must be a valid secure HTTPS URL.'); return trimmed; }
    @TestVisible private static Boolean isValidHttps(String value) { if (String.isBlank(value)) return false; try { Url parsed = new Url(value.trim()); return parsed.getProtocol() == 'https' && String.isNotBlank(parsed.getHost()) && !value.contains('\n') && !value.contains('\r'); } catch (Exception ignored) { return false; } }
    private static String normalizeView(String value) { String normalized = String.isBlank(value) ? VIEW_CURRENT : value.trim().toUpperCase(); if (normalized != VIEW_CURRENT && normalized != VIEW_PAST) throw friendly('Unsupported deployment window view.'); return normalized; }
    private static String blankToNull(String value) { return String.isBlank(value) ? null : value.trim(); }
    private static AuraHandledException friendly(String message) { return new AuraHandledException(message); }
}