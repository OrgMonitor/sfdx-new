import { LightningElement, api } from 'lwc';

const WHY_ITEMS = [
    { id: 'w1', label: 'Prevent unauthorized changes' },
    { id: 'w2', label: 'Enforce release compliance' },
    { id: 'w3', label: 'Reduce risks and improve compliance' },
];

export default class WizardSidebar extends LightningElement {
    @api steps = [];
    @api currentStepIndex = 0;

    get whyItems() {
        return WHY_ITEMS;
    }

    get displaySteps() {
        return this.steps.map((step, idx) => {
            const isCompleted = idx < this.currentStepIndex;
            const isCurrent = idx === this.currentStepIndex;
            const isUpcoming = idx > this.currentStepIndex;
            return {
                ...step,
                index: idx,
                isCompleted,
                isCurrent,
                isDisabled: isUpcoming,
                liClass: `wsb-step-item${isCurrent ? ' wsb-step-item--current' : ''}`,
                btnClass: `wsb-step-btn${isCurrent ? ' wsb-step-btn--current' : ''}${isCompleted ? ' wsb-step-btn--completed' : ''}`,
                indicatorClass: `wsb-step-indicator${isCompleted ? ' wsb-step-indicator--completed' : ''}${isCurrent ? ' wsb-step-indicator--current' : ''}`,
                ariaCurrent: isCurrent ? 'step' : null,
                ariaLabel: `Step ${step.number}: ${step.label}${isCompleted ? ', completed' : isCurrent ? ', current step' : ''}`,
            };
        });
    }

    handleStepClick(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.dispatchEvent(new CustomEvent('stepselect', {
            detail: { stepIndex: index },
        }));
    }
}