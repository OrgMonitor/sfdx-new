import { LightningElement, track, wire } from 'lwc';
import getInactiveUsers from '@salesforce/apex/InactiveUserController.getInactiveUsers';
import deactivateUsers from '@salesforce/apex/InactiveUserController.deactivateUsers';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import LightningConfirm from 'lightning/confirm';

const COLUMNS = [
    { label: 'Name', fieldName: 'Name', sortable: true },
    { label: 'Email', fieldName: 'Email' },
    { label: 'Profile', fieldName: 'ProfileName' },
    {
        label: 'Last login',
        fieldName: 'LastLoginDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit'
        }
    },
    {
        label: 'Days Inactive',
        fieldName: 'DaysInactive',
        type: 'number'
    }
];

export default class InactiveUserManager extends LightningElement {

    columns = COLUMNS;

    @track filterMode = 'days';

    @track days = 90;
    @track fromDate = null;
    @track toDate = null;

    @track users = [];
    @track selectedIds = [];
    @track isLoading = false;

    wiredResult;

    get today() {
        return new Date().toISOString().split('T')[0];
    }

    get filterModeOptions() {
        return [
            { label: 'Days Inactive', value: 'days' },
            { label: 'Date Range', value: 'date' }
        ];
    }

    get isDaysMode() {
        return this.filterMode === 'days';
    }

    get isDateMode() {
        return this.filterMode === 'date';
    }

    get wireDays() {
        return this.filterMode === 'days' ? this.days : null;
    }

    get wireFromDate() {
        return this.filterMode === 'date' ? this.fromDate : null;
    }

    get wireToDate() {
        return this.filterMode === 'date' ? this.toDate : null;
    }

    get totalCount() {
        return this.users.length;
    }

    get neverLoggedInCount() {
        return this.users.filter(u => !u.LastLoginDate).length;
    }

    get selectedCount() {
        return this.selectedIds.length;
    }

    get selectedCountLabel() {
        return `${this.selectedCount} selected`;
    }

    get deactivateAllLabel() {
        return `Deactivate All (${this.totalCount})`;
    }

    get deactivateSelectedDisabled() {
        return this.selectedCount === 0 || this.isLoading;
    }

    get deactivateAllDisabled() {
        return this.totalCount === 0 || this.isLoading;
    }

    @wire(getInactiveUsers, {
        days: '$wireDays',
        fromDate: '$wireFromDate',
        toDate: '$wireToDate'
    })
    wiredUsers(result) {
        this.wiredResult = result;

        if (result.data) {
            this.users = result.data.map(u => ({
                ...u,
                ProfileName: u.Profile?.Name || '',
                DaysInactive: u.LastLoginDate
                    ? Math.floor(
                        (Date.now() - new Date(u.LastLoginDate).getTime()) /
                        86400000
                    )
                    : null
            }));
        } else if (result.error) {
            this.users = [];

            this.showToast(
                'Error',
                result.error.body?.message || 'Failed to load users',
                'error'
            );
        }
    }

    handleFilterModeChange(event) {
        this.filterMode = event.detail.value;

        this.users = [];
        this.selectedIds = [];

        if (this.filterMode === 'days') {
            this.days = 90;
            this.fromDate = null;
            this.toDate = null;
        } else {
            this.days = null;
            this.fromDate = '';
            this.toDate = this.today;
        }
    }

    handleDaysChange(event) {
        this.users = [];
        this.selectedIds = [];

        const val = parseInt(event.detail.value, 10);

        this.days = val > 0 ? val : 90;
    }

    handleFromDateChange(event) {
        const val = event.detail.value;

        if (this.toDate && val > this.toDate) {
            this.showToast(
                'Validation Error',
                'From date cannot be after To date',
                'warning'
            );
            return;
        }

        this.users = [];
        this.selectedIds = [];
        this.fromDate = val;
    }

    handleToDateChange(event) {
        const val = event.detail.value;

        if (this.fromDate && val < this.fromDate) {
            this.showToast(
                'Validation Error',
                'To date cannot be before From date',
                'warning'
            );
            return;
        }

        this.users = [];
        this.selectedIds = [];
        this.toDate = val;
    }

    handleRowSelection(event) {
        this.selectedIds =
            event.detail.selectedRows.map(row => row.Id);
    }

    handleDeactivateSelected() {
        this.runDeactivate(this.selectedIds);
    }

    async handleDeactivateAll() {
        const allIds = (this.users || []).map(user => user.Id);
        if (!allIds.length) {
            return;
        }
        const confirmed = await LightningConfirm.open({
            message: `Are you sure you want to deactivate ${allIds.length} user(s)? This action cannot be undone.`,
            variant: 'header',
            label: 'Confirm User Deactivation'
        });
        if (!confirmed) {
            return;
        }
        this.runDeactivate(allIds);
    }

    async runDeactivate(ids) {

        if (!ids?.length) {
            return;
        }

        this.isLoading = true;

        try {

            const result = await deactivateUsers({
                userIds: ids
            });

            if (result.success) {

                this.showToast(
                    'Success',
                    `${result.count} user(s) deactivated`,
                    'success'
                );

                this.selectedIds = [];

                await refreshApex(this.wiredResult);

            } else {

                this.showToast(
                    'Error',
                    result.error,
                    'error'
                );
            }

        } catch (e) {

            this.showToast(
                'Error',
                e.body?.message || e.message,
                'error'
            );

        } finally {
            this.isLoading = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}