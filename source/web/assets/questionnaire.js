export function createQuestionnaireState(request) {
    const source = request || {};
    let questions = Array.isArray(source.questions) ? source.questions : [];
    if (questions.length === 0) {
        questions = [{
            header: 'Question',
            question: String(source.question || ''),
            options: [],
            multiSelect: false,
            allowFreeformInput: true,
        }];
    }

    return {
        id: String(source.id || ''),
        structured: source.structured === true,
        title: String(source.title || 'Your input is needed'),
        currentIndex: 0,
        questions: questions.map((question, index) => {
            const options = Array.isArray(question && question.options)
                ? question.options
                    .map((option) => ({
                        label: String((option && option.label) || ''),
                        description: String((option && option.description) || ''),
                    }))
                    .filter((option) => option.label)
                : [];
            return {
                header: String((question && question.header) || `Question ${index + 1}`),
                question: String((question && question.question) || ''),
                options,
                multiSelect: !!(question && question.multiSelect && options.length > 1),
                allowFreeformInput: options.length === 0 || !!(question && question.allowFreeformInput),
                selectedOptions: [],
                freeText: '',
                optionFocusIndex: 0,
            };
        }),
    };
}

export function getQuestionnaireOptionFocusIndex(currentIndex, key, optionCount) {
    const count = Math.max(0, Number(optionCount) || 0);
    if (count === 0) return 0;
    const current = Math.max(0, Math.min(count - 1, Number(currentIndex) || 0));
    if (key === 'Home') return 0;
    if (key === 'End') return count - 1;
    if (key === 'ArrowDown' || key === 'ArrowRight') return (current + 1) % count;
    if (key === 'ArrowUp' || key === 'ArrowLeft') return (current - 1 + count) % count;
    return current;
}

export function setQuestionnaireStep(state, index) {
    if (!state || !Array.isArray(state.questions) || state.questions.length === 0) return 0;
    const next = Math.max(0, Math.min(state.questions.length - 1, Number(index) || 0));
    state.currentIndex = next;
    return next;
}

export function toggleQuestionnaireOption(state, questionIndex, label) {
    const question = state && state.questions && state.questions[questionIndex];
    if (!question || !question.options.some((option) => option.label === label)) return;
    if (!question.multiSelect) {
        question.selectedOptions = [label];
        return;
    }
    const selected = new Set(question.selectedOptions);
    if (selected.has(label)) selected.delete(label); else selected.add(label);
    question.selectedOptions = Array.from(selected);
}

export function setQuestionnaireFreeText(state, questionIndex, value) {
    const question = state && state.questions && state.questions[questionIndex];
    if (!question || !question.allowFreeformInput) return;
    question.freeText = String(value || '');
}

export function isQuestionnaireStepComplete(state, questionIndex) {
    const question = state && state.questions && state.questions[questionIndex];
    if (!question) return false;
    return question.selectedOptions.length > 0 ||
        (question.allowFreeformInput && question.freeText.trim().length > 0);
}

export function isQuestionnaireComplete(state) {
    return !!state && state.questions.length > 0 &&
        state.questions.every((_, index) => isQuestionnaireStepComplete(state, index));
}

export function serializeQuestionnaireAnswer(state) {
    if (!state || !Array.isArray(state.questions) || state.questions.length === 0) return '';
    if (!state.structured) {
        const question = state.questions[0];
        return question.freeText.trim() || question.selectedOptions[0] || '';
    }
    return JSON.stringify({
        answers: state.questions.map((question) => ({
            header: question.header,
            selectedOptions: [...question.selectedOptions],
            freeText: question.freeText.trim(),
        })),
    });
}
