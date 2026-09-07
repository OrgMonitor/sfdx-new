/** Thin LWC facade for DeploymentWindowService. */
public with sharing class DeploymentWindowController {
    @AuraEnabled(cacheable=true) public static DeploymentWindowService.ListResult listWindows(String viewName, Integer pageNumber, Integer pageSize) {
        return DeploymentWindowService.listWindows(viewName, pageNumber, pageSize);
    }
    @AuraEnabled(cacheable=true) public static DeploymentWindowService.WindowDto getWindow(Id recordId) {
        return DeploymentWindowService.getWindow(recordId);
    }
    @AuraEnabled(cacheable=true) public static DeploymentWindowService.Capabilities getCapabilities() {
        return DeploymentWindowService.getCapabilities();
    }
    @AuraEnabled(cacheable=true) public static List<DeploymentWindowService.UserOption> searchUsers(String searchTerm) {
        return DeploymentWindowService.searchUsers(searchTerm);
    }
    @AuraEnabled public static Id saveWindow(DeploymentWindowService.SaveRequest request) {
        try { return DeploymentWindowService.saveWindow(request); }
        catch (AuraHandledException error) { throw error; }
        catch (Exception ignored) { throw new AuraHandledException('The deployment window could not be saved. Review your access and field values.'); }
    }
    @AuraEnabled public static Id saveWindowFromWorkspace(
        String requestJson,
        String startDateTimeIso,
        String endDateTimeIso
    ) {
        try {
            DeploymentWindowService.SaveRequest request = String.isBlank(requestJson)
                ? new DeploymentWindowService.SaveRequest()
                : (DeploymentWindowService.SaveRequest) JSON.deserialize(
                    requestJson, DeploymentWindowService.SaveRequest.class
                );
            request.startDateTime = parseIsoDateTime(startDateTimeIso, 'Start Date/Time');
            request.endDateTime = parseIsoDateTime(endDateTimeIso, 'End Date/Time');
            return DeploymentWindowService.saveWindow(request);
        } catch (AuraHandledException error) { throw error; }
        catch (Exception ignored) { throw new AuraHandledException('The deployment window could not be saved. Review the schedule and try again.'); }
    }
    @AuraEnabled public static DeploymentWindowService.WindowDto transition(Id recordId, String actionName) {
        try { return DeploymentWindowService.transition(recordId, actionName); }
        catch (AuraHandledException error) { throw error; }
        catch (Exception ignored) { throw new AuraHandledException('The deployment window status could not be changed. Refresh and try again.'); }
    }
    private static Datetime parseIsoDateTime(String value, String label) {
        if (String.isBlank(value)) throw new AuraHandledException(label + ' is required.');
        try { return (Datetime) JSON.deserialize(JSON.serialize(value), Datetime.class); }
        catch (Exception ignored) { throw new AuraHandledException(label + ' is invalid.'); }
    }
}