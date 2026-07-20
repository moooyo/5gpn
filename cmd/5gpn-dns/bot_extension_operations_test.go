package main

import (
	"context"
	"errors"
	"testing"
)

func TestBotExtensionOperationGuardCancelsSupersededOwnerWork(t *testing.T) {
	bt := &Bot{}
	owner, firstGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	first, finishFirst := bt.startBotExtensionOperation(context.Background(), owner, firstGeneration)
	owner, secondGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	second, finishSecond := bt.startBotExtensionOperation(context.Background(), owner, secondGeneration)
	defer finishSecond()
	finishFirst()

	if !errors.Is(first.Err(), context.Canceled) {
		t.Fatalf("superseded operation error = %v", first.Err())
	}
	if second.Err() != nil {
		t.Fatalf("new operation was cancelled by old cleanup: %v", second.Err())
	}
	bt.cancelBotExtensionOperation(owner.adminID, owner.chatID)
	if !errors.Is(second.Err(), context.Canceled) {
		t.Fatalf("explicit cancellation error = %v", second.Err())
	}
}

func TestBotExtensionOperationGuardRejectsLateOlderGeneration(t *testing.T) {
	bt := &Bot{}
	owner, olderGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	owner, newerGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	newer, finishNewer := bt.startBotExtensionOperation(context.Background(), owner, newerGeneration)
	defer finishNewer()
	older, finishOlder := bt.startBotExtensionOperation(context.Background(), owner, olderGeneration)
	defer finishOlder()
	if !errors.Is(older.Err(), context.Canceled) {
		t.Fatalf("late old operation error = %v", older.Err())
	}
	if newer.Err() != nil {
		t.Fatalf("late old operation cancelled newer work: %v", newer.Err())
	}

	owner, cancelledGeneration, err := bt.extensionStateStore().BeginOperation(222, 222)
	if err != nil {
		t.Fatal(err)
	}
	bt.extensionStateStore().CancelOwner(222, 222)
	cancelled, finishCancelled := bt.startBotExtensionOperation(context.Background(), owner, cancelledGeneration)
	defer finishCancelled()
	if !errors.Is(cancelled.Err(), context.Canceled) {
		t.Fatalf("cancel-before-start error = %v", cancelled.Err())
	}
}

func TestBotExtensionCancellationCutoffDoesNotCancelNewerWork(t *testing.T) {
	bt := &Bot{}
	owner, oldGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	oldCtx, finishOld := bt.startBotExtensionOperation(context.Background(), owner, oldGeneration)
	defer finishOld()
	removed, cutoff := bt.extensionStateStore().CancelOwnerWithGeneration(111, 111)
	if !removed || cutoff <= oldGeneration {
		t.Fatalf("cancellation state = removed:%v cutoff:%d old:%d", removed, cutoff, oldGeneration)
	}
	owner, newGeneration, err := bt.extensionStateStore().BeginOperation(111, 111)
	if err != nil {
		t.Fatal(err)
	}
	newCtx, finishNew := bt.startBotExtensionOperation(context.Background(), owner, newGeneration)
	defer finishNew()
	if bt.cancelBotExtensionOperationThrough(111, 111, cutoff) {
		t.Fatal("older cancellation cutoff cancelled newer work")
	}
	if newCtx.Err() != nil {
		t.Fatalf("newer operation error = %v", newCtx.Err())
	}
	if !errors.Is(oldCtx.Err(), context.Canceled) {
		t.Fatalf("older operation error = %v", oldCtx.Err())
	}

	other := &Bot{}
	otherOwner, generation, err := other.extensionStateStore().BeginOperation(222, 222)
	if err != nil {
		t.Fatal(err)
	}
	ctx, finish := other.startBotExtensionOperation(context.Background(), otherOwner, generation)
	defer finish()
	_, cutoff = other.extensionStateStore().CancelOwnerWithGeneration(222, 222)
	if !other.cancelBotExtensionOperationThrough(222, 222, cutoff) {
		t.Fatal("cancellation cutoff did not cancel older work")
	}
	if !errors.Is(ctx.Err(), context.Canceled) {
		t.Fatalf("cancelled operation error = %v", ctx.Err())
	}
}

func TestBotExtensionFetchConcurrencyIsBounded(t *testing.T) {
	bt := &Bot{}
	releaseOne, err := bt.acquireBotExtensionFetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer releaseOne()
	releaseTwo, err := bt.acquireBotExtensionFetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer releaseTwo()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := bt.acquireBotExtensionFetch(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("third fetch error = %v, want context cancellation", err)
	}
}

func TestBotExtensionRenderConcurrencyIsSerialized(t *testing.T) {
	bt := &Bot{}
	release, err := bt.acquireBotExtensionRender(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := bt.acquireBotExtensionRender(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("second render error = %v, want context cancellation", err)
	}
}
