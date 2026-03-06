package controller

import (
	"context"
	"crypto/sha256"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/go-redis/redis/v9"
	sandboxv1alpha1 "github.com/sandbox-operator/sandbox-operator/api/v1alpha1"
)

const (
	// cacheTTL is how long a package-set cache entry remains valid.
	cacheTTL = 24 * time.Hour

	// cacheKeyPrefix namespaces all sandbox entries in Redis.
	cacheKeyPrefix = "sandbox:pkgcache:"

	// cacheImageField is the hash field storing the pre-built image reference.
	cacheImageField = "imageRef"
)

// CacheManager wraps a Redis client and provides deterministic cache key
// generation and lookup for runtime+package combinations.
type CacheManager struct {
	client *redis.Client
}

// NewCacheManager creates a CacheManager connected to the given Redis address.
// Returns an error if Redis is unreachable within 5 seconds.
func NewCacheManager(redisAddr, redisPassword string) (*CacheManager, error) {
	rdb := redis.NewClient(&redis.Options{
		Addr:         redisAddr,
		Password:     redisPassword,
		DB:           0,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
		PoolSize:     10,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping failed at %s: %w", redisAddr, err)
	}

	return &CacheManager{client: rdb}, nil
}

// PackageCacheKey derives a deterministic, collision-resistant key from the
// runtime type and an unordered list of package specifiers.
//
// The key format is: sandbox:pkgcache:<8-byte-sha256-hex>
// Packages are sorted before hashing so ["numpy", "pandas"] == ["pandas", "numpy"].
func PackageCacheKey(runtime sandboxv1alpha1.RuntimeType, packages []string) string {
	sorted := make([]string, len(packages))
	copy(sorted, packages)
	sort.Strings(sorted)

	payload := string(runtime) + ":" + strings.Join(sorted, ",")
	h := sha256.Sum256([]byte(payload))
	return fmt.Sprintf("%s%x", cacheKeyPrefix, h[:8])
}

// CacheEntry holds the cached artefact for a package set.
type CacheEntry struct {
	// ImageRef is the pre-built OCI image reference with packages baked in,
	// or the base image reference if packages were installed at runtime.
	ImageRef string

	// InstallScript is the pre-computed install command stored alongside the entry.
	InstallScript string
}

// Lookup checks Redis for an existing cache entry. Returns (entry, true, nil) on
// a hit, (nil, false, nil) on a miss, and (nil, false, err) on a Redis error.
func (c *CacheManager) Lookup(ctx context.Context, key string) (*CacheEntry, bool, error) {
	vals, err := c.client.HGetAll(ctx, key).Result()
	if err == redis.Nil || len(vals) == 0 {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("redis HGetAll(%s): %w", key, err)
	}

	entry := &CacheEntry{
		ImageRef:      vals[cacheImageField],
		InstallScript: vals["installScript"],
	}
	return entry, true, nil
}

// Store writes a cache entry with TTL. Existing entries are overwritten so
// the TTL resets on each successful execution.
func (c *CacheManager) Store(ctx context.Context, key string, entry CacheEntry) error {
	pipe := c.client.Pipeline()
	pipe.HSet(ctx, key, map[string]interface{}{
		cacheImageField:  entry.ImageRef,
		"installScript":  entry.InstallScript,
		"cachedAt":       time.Now().UTC().Format(time.RFC3339),
	})
	pipe.Expire(ctx, key, cacheTTL)

	_, err := pipe.Exec(ctx)
	if err != nil {
		return fmt.Errorf("redis Store(%s): %w", key, err)
	}
	return nil
}

// Invalidate removes a cache entry. Used when a package install fails to
// prevent a bad entry from poisoning future executions.
func (c *CacheManager) Invalidate(ctx context.Context, key string) error {
	return c.client.Del(ctx, key).Err()
}

// HealthCheck pings Redis and returns an error if it is unreachable.
func (c *CacheManager) HealthCheck(ctx context.Context) error {
	return c.client.Ping(ctx).Err()
}

// Close releases the Redis connection pool.
func (c *CacheManager) Close() error {
	return c.client.Close()
}
