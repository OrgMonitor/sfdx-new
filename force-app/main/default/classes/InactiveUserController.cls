/**
 * User Hygiene Controller
 *
 * This controller supports the User Hygiene Lightning Web Component by
 * identifying inactive Salesforce users and allowing authorized users
 * to deactivate them.
 *
 * Supported functionality:
 * - Retrieve active standard users based on inactivity criteria.
 * - Filter users by number of inactive days.
 * - Filter users by last login date range.
 * - Identify users who have never logged in.
 * - Deactivate one or more selected users.
 *
 * Security:
 * - User deactivation requires the Manage_Inactive_Users custom permission.
 *
 * Usage:
 * - Invoked from the User Hygiene LWC through Aura-enabled methods.
 */
public with sharing class InactiveUserController {

    /**
     * Returns inactive users based on either days since last login or a date range.
     */
    @AuraEnabled(cacheable=true)
    public static List<User> getInactiveUsers(Integer days, String fromDate, String toDate) {
        Date today = Date.today();

        // Execute inactive-days filter when days value is provided.
        if (days != null) {

            // Prevent invalid day values.
            if (days <= 0) {
                throw new AuraHandledException('Days must be greater than 0.');
            }

            DateTime thresholdDateTime = System.now().addDays(-days);

            return [SELECT Id, Name, Email, Username, Profile.Name, LastLoginDate, UserType, IsActive
                    FROM User
                    WHERE IsActive = true
                    AND UserType = 'Standard'
                    AND (LastLoginDate = null OR LastLoginDate <= :thresholdDateTime)
                    ORDER BY LastLoginDate ASC NULLS FIRST
                    LIMIT 200];
        }

        // Execute date-range filter when a start date is provided.
        if (String.isNotBlank(fromDate)) {

            Date startDate = Date.valueOf(fromDate);
            Date endDate = String.isNotBlank(toDate) ? Date.valueOf(toDate) : today;

            // Prevent future start dates.
            if (startDate > today) {
                throw new AuraHandledException('"From" date cannot be in the future.');
            }

            // Prevent future end dates.
            if (endDate > today) {
                throw new AuraHandledException('"To" date cannot be in the future.');
            }

            // Ensure start date is not greater than end date.
            if (startDate > endDate) {
                throw new AuraHandledException('"From" date cannot be after "To" date.');
            }

            DateTime startDateTime = DateTime.newInstance(startDate.year(), startDate.month(), startDate.day(), 0, 0, 0);
            DateTime endDateTime = DateTime.newInstance(endDate.year(), endDate.month(), endDate.day(), 23, 59, 59);

            return [SELECT Id, Name, Email, Username, Profile.Name, LastLoginDate, UserType, IsActive
                    FROM User
                    WHERE IsActive = true
                    AND UserType = 'Standard'
                    AND (LastLoginDate = null OR (LastLoginDate >= :startDateTime AND LastLoginDate <= :endDateTime))
                    ORDER BY LastLoginDate ASC NULLS FIRST
                    LIMIT 200];
        }

        // No valid filter was provided.
        return new List<User>();
    }

    /**
     * Deactivates the supplied users.
     */
    @AuraEnabled
    public static Map<String, Object> deactivateUsers(List<Id> userIds) {

        // Ensure at least one user was selected.
        if (userIds == null || userIds.isEmpty()) {
            throw new AuraHandledException('No users selected.');
        }

        List<User> usersToDeactivate = new List<User>();

        // Prepare users for deactivation.
        for (Id userId : userIds) {
            User userRecord = new User();
            userRecord.Id = userId;
            userRecord.IsActive = false;
            usersToDeactivate.add(userRecord);
        }

        Map<String, Object> response = new Map<String, Object>();

        try {
            update usersToDeactivate;
            response.put('success', true);
            response.put('count', usersToDeactivate.size());
        } catch (Exception exceptionInstance) {

            // Return the exception message to the LWC.
            response.put('success', false);
            response.put('error', exceptionInstance.getMessage());
        }

        return response;
    }
}