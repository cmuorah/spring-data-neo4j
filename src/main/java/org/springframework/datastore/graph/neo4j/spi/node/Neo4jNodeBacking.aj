package org.springframework.datastore.graph.neo4j.spi.node;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.*;

import org.aspectj.lang.reflect.FieldSignature;
import org.neo4j.graphdb.*;
import org.neo4j.graphdb.traversal.*;
import org.neo4j.graphdb.traversal.Traverser;
import org.neo4j.helpers.collection.IterableWrapper;
import org.neo4j.index.IndexService;
import org.neo4j.kernel.EmbeddedGraphDatabase;
import org.neo4j.util.GraphDatabaseUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.InvalidDataAccessResourceUsageException;
import org.springframework.datastore.graph.api.GraphEntityProperty;
import org.springframework.datastore.graph.api.NodeBacked;
import org.springframework.datastore.graph.api.RelationshipBacked;

import org.springframework.datastore.graph.api.GraphEntity;
import org.springframework.datastore.graph.neo4j.fieldaccess.DelegatingFieldAccessorFactory;
import org.springframework.datastore.graph.neo4j.fieldaccess.FieldAccessor;
import org.springframework.persistence.support.AbstractTypeAnnotatingMixinFields;
import org.springframework.persistence.support.EntityInstantiator;
import org.springframework.util.ObjectUtils;

import org.springframework.core.convert.ConversionService;

import javax.transaction.Status;
import javax.transaction.SystemException;

/**
 * Aspect to turn an object annotated with GraphEntity into a graph entity using Neo4J.
 * Delegates all field access (except for fields assumed to be transient)
 * to an underlying Neo4 graph node.
 * 
 * @author Rod Johnson
 */
public aspect Neo4jNodeBacking extends AbstractTypeAnnotatingMixinFields<GraphEntity, NodeBacked> {
	
	//-------------------------------------------------------------------------
	// Configure aspect for whole system.
	// init() method can be invoked automatically if the aspect is a Spring
	// bean, or called in user code.
	//-------------------------------------------------------------------------
	// Aspect shared Neo4J Graph Database Service
	private GraphDatabaseService graphDatabaseService;
	
    public EntityInstantiator<NodeBacked, Node> graphEntityInstantiator;

	private DelegatingFieldAccessorFactory fieldAccessorFactory;

	public EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator;
	
    private IndexService indexService;
    
    private ConversionService conversionService;

    @Autowired
	public void init(GraphDatabaseService gds, EntityInstantiator<NodeBacked, Node> graphEntityInstantiator, 
			EntityInstantiator<RelationshipBacked, Relationship> relationshipEntityInstantiator, IndexService indexService,
			ConversionService conversionService) {
		this.graphDatabaseService = gds;
		this.graphEntityInstantiator = graphEntityInstantiator;
		this.relationshipEntityInstantiator = relationshipEntityInstantiator;
        this.indexService = indexService;
		this.conversionService = conversionService;
        this.fieldAccessorFactory = new DelegatingFieldAccessorFactory(graphEntityInstantiator, relationshipEntityInstantiator);
	}
	
	
	//-------------------------------------------------------------------------
	// Advise user-defined constructors of NodeBacked objects to create a new
	// Neo4J backing node
	//-------------------------------------------------------------------------
	pointcut arbitraryUserConstructorOfNodeBackedObject(NodeBacked entity) : 
		execution((@GraphEntity *).new(..)) &&
		!execution((@GraphEntity *).new(Node)) &&
		this(entity);  // && !cflow(execution(* fromStateInternal(..));
	
	
	// Create a new node in the Graph if no Node was passed in a constructor
	before(NodeBacked entity) : arbitraryUserConstructorOfNodeBackedObject(entity) {
        if (!transactionIsRunning()) {
            log.warn("New Nodebacked created outside of transaction "+ entity.getClass());

        } else {
            createAndAssignNode(entity);
        }
	}

    private void createAndAssignNode(NodeBacked entity) {
		try {
			entity.setUnderlyingNode(graphDatabaseService.createNode());
			log.info("User-defined constructor called on class " + entity.getClass() + "; created Node [" + entity.getUnderlyingNode() +"]; " +
					"Updating metamodel");
			postEntityCreation(entity);
		} catch(NotInTransactionException e) {
			throw new InvalidDataAccessResourceUsageException("Not in a Neo4j transaction.", e);
		}
    }

    private void postEntityCreation(NodeBacked entity) {
        Node subReference = Neo4jHelper.obtainSubreferenceNode(entity.getClass(), graphDatabaseService);
        entity.getUnderlyingNode().createRelationshipTo(subReference, Neo4jHelper.INSTANCE_OF_RELATIONSHIP_TYPE);
        GraphDatabaseUtil.incrementAndGetCounter(subReference, Neo4jHelper.SUBREFERENCE_NODE_COUNTER_KEY);
    }

    private boolean transactionIsRunning() {
        try {
            return ((EmbeddedGraphDatabase)graphDatabaseService).getConfig().getTxModule().getTxManager().getStatus() != Status.STATUS_NO_TRANSACTION;
        } catch (SystemException e) {
            log.error("Error accessing TransactionManager",e);
            return false;
        }
    }

	// Introduced field
	private Node NodeBacked.underlyingNode;
    private Map<Field,Object> NodeBacked.dirty;

	public void NodeBacked.setUnderlyingNode(Node n) {
		this.underlyingNode = n;
	}
	
	public Node NodeBacked.getUnderlyingNode() {
		return underlyingNode;
	}
	
    public boolean NodeBacked.hasUnderlyingNode() {
        return underlyingNode!=null;
    }

	public Relationship NodeBacked.relateTo(NodeBacked nb, RelationshipType type) {
		return this.underlyingNode.createRelationshipTo(nb.getUnderlyingNode(), type);
	}

	public Long NodeBacked.getNodeId() {
        if (!hasUnderlyingNode()) return null;
		return underlyingNode.getId();
	}


    private boolean NodeBacked.isDirty() {
        return this.dirty!=null && !this.dirty.isEmpty();
    }
    private boolean NodeBacked.isDirty(Field f) {
        return this.dirty!=null && this.dirty.containsKey(f);
    }

    private void NodeBacked.clearDirty() {
        if (this.dirty!=null) this.dirty.clear();
    }
    private String NodeBacked.dump() {
        if (this.dirty!=null) return this.dirty.toString();
        return "";
    }

    private void NodeBacked.addDirty(Field f, Object previousValue) {
        if (this.dirty==null) this.dirty=new HashMap<Field, Object>();
        this.dirty.put(f,previousValue);
    }

    public  Iterable<? extends NodeBacked> NodeBacked.find(final Class<? extends NodeBacked> targetType, TraversalDescription traversalDescription) {
        if (!hasUnderlyingNode()) throw new IllegalStateException("No node attached to " + this);
        final Traverser traverser = traversalDescription.traverse(this.getUnderlyingNode());
        final EntityInstantiator<NodeBacked,Node> instantiator=Neo4jNodeBacking.aspectOf().graphEntityInstantiator;
        return new Neo4jNodeBacking.NodeBackedNodeIterableWrapper(traverser, targetType);
    }
    /*
    public Iterable<? extends NodeBacked> NodeBacked.traverse(TraversalDescription traversalDescription) {
        final Class<? extends NodeBacked> target = this.getClass();
        return this.traverse(target,traversalDescription);
    }
    */

    /*
    public <R extends RelationshipBacked, N extends NodeBacked> R NodeBacked.relateTo(N node, Class<R> relationshipType, String type) {
        Relationship rel = this.getUnderlyingNode().createRelationshipTo(node.getUnderlyingNode(), DynamicRelationshipType.withName(type));
        Neo4jNodeBacking.aspectOf().relationshipEntityInstantiator.createEntityFromState(rel, relationshipType);
    }
    */
    public RelationshipBacked NodeBacked.relateTo(NodeBacked node, Class<? extends RelationshipBacked> relationshipType, String type) {
        Relationship rel = this.getUnderlyingNode().createRelationshipTo(node.getUnderlyingNode(), DynamicRelationshipType.withName(type));
        return Neo4jNodeBacking.aspectOf().relationshipEntityInstantiator.createEntityFromState(rel, relationshipType);
    }

    public RelationshipBacked NodeBacked.getRelationshipTo(NodeBacked node, Class<? extends RelationshipBacked> relationshipType, String type) {
        Node myNode=this.getUnderlyingNode();
        Node otherNode=node.getUnderlyingNode();
        for (Relationship rel : this.getUnderlyingNode().getRelationships(DynamicRelationshipType.withName(type))) {
            if (rel.getOtherNode(myNode).equals(otherNode)) return Neo4jNodeBacking.aspectOf().relationshipEntityInstantiator.createEntityFromState(rel, relationshipType);
        }
        return null;
    }

    private Iterable<Map.Entry<Field,Object>> NodeBacked.eachDirty() {
        return this.dirty!=null ? this.dirty.entrySet() : Collections.<Field, Object>emptyMap().entrySet();
    }

	//-------------------------------------------------------------------------
	// Equals and hashCode for Neo4j entities.
	// Final to prevent overriding.
	//-------------------------------------------------------------------------
	// TODO could use template method for further checks if needed
	public final boolean NodeBacked.equals(Object obj) {
        if (obj == this) return true;
        if (!hasUnderlyingNode()) return false;
		if (obj instanceof NodeBacked) {
			return this.getUnderlyingNode().equals(((NodeBacked) obj).getUnderlyingNode());
		}
		return false;
	}
	
	public final int NodeBacked.hashCode() {
        if (!hasUnderlyingNode()) return System.identityHashCode(this);
		return getUnderlyingNode().hashCode();
	}



    private Object getValueFromEntity(Field field, NodeBacked entity) {
        try {
            field.setAccessible(true);
            return field.get(entity);
        } catch (IllegalAccessException e) {
            throw new RuntimeException("Error accessing field "+field+" in "+entity.getClass(),e);
        }
    }
    /*
    always runs inside a transaction
     */
    private ShouldProceedOrReturn getNodePropertyOrRelationship(Field field, NodeBacked entity) {
        // TODO fix arrays, TODO serialize other types as byte[] or string (for indexing, querying) via Annotation
        if (isIdField(field)) return new ShouldProceedOrReturn(entity.getUnderlyingNode().getId());
        if (Modifier.isTransient(field.getModifiers())) return new ShouldProceedOrReturn();
        if (isNeo4jPropertyType(field.getType()) || isDeserializableField(field)) {
            String propName = DelegatingFieldAccessorFactory.getNeo4jPropertyName(field);
            log.info("GET " + field + " <- Neo4J simple node property [" + propName + "]");
            Node node = entity.getUnderlyingNode();
            Object nodeProperty = deserializePropertyValue(node.getProperty(propName, getDefaultValue(field.getType())), field.getType());
            return new ShouldProceedOrReturn(nodeProperty);
        }

        FieldAccessor accessor = fieldAccessorFactory.forField(field);
        if (accessor!=null) {
            Object obj = accessor.getValue(entity);
            if (obj != null) {
                return new ShouldProceedOrReturn(obj);
            }
        }
        log.info("Ignored GET " + field + ": " + field.getType().getName() + " not primitive or GraphEntity");
        return new ShouldProceedOrReturn();
    }

    private boolean isIdField(Field field) {
        if (!field.getName().equals("id")) return false;
        final Class<?> type = field.getType();
        return type.equals(Long.class) || type.equals(long.class);
    }

    private Object getDefaultValue(Class<?> type) {
        if (type.isPrimitive()) {
            if (type.equals(boolean.class)) return false;
            return 0;
        }
        return null;
    }

    private void flushDirty(NodeBacked entity) {
        if (transactionIsRunning()) {
            final boolean newNode=!entity.hasUnderlyingNode();
            if (newNode) {
                createAndAssignNode(entity);
            }
            if (entity.isDirty()) {
                for (final Map.Entry<Field,Object> entry : entity.eachDirty()) {
                    final Field field = entry.getKey();
                    log.warn("Flushing dirty Entity new node "+newNode+" field "+field);
                    if (!newNode) {
                        checkConcurrentModification(entity, entry, field);
                    }
                    setNodePropertyOrRelationship(field, entity, getValueFromEntity(field,entity));
                }
                entity.clearDirty();
            }
        }
    }



    private void checkConcurrentModification(NodeBacked entity, Map.Entry<Field, Object> entry, Field field) {
        final Object nodeValue = getNodePropertyOrRelationship(field, entity).value;
        final Object previousValue = entry.getValue();
        if (!ObjectUtils.nullSafeEquals(nodeValue,previousValue)) {
            throw new ConcurrentModificationException("Node "+entity.getUnderlyingNode()+" field "+field+" changed in between previous "+ previousValue +" current "+nodeValue); // todo or just overwrite
        }
    }

    /*
    always called inside a transaction
     */

    private ShouldProceedOrReturn setNodePropertyOrRelationship(Field field, NodeBacked entity, Object newVal) {
        try {
            if (isIdField(field)) return new ShouldProceedOrReturn(null);
            if (Modifier.isFinal(field.getModifiers())) return new ShouldProceedOrReturn(newVal);
            if (Modifier.isTransient(field.getModifiers())) return new ShouldProceedOrReturn(true, newVal);
            if (isNeo4jPropertyType(field.getType()) || isSerializableField(field)) {
                String propName = DelegatingFieldAccessorFactory.getNeo4jPropertyName(field);
                Node node = entity.getUnderlyingNode();
                if (newVal==null) {
                    node.removeProperty(propName);
                    if (isIndexedProperty(field)) indexService.removeIndex(node,propName);
                } else {
                    node.setProperty(propName, serializePropertyValue(newVal, field.getType()));
                    if (isIndexedProperty(field)) indexService.index(node,propName,newVal);
                }
                log.info("SET " + field + " -> Neo4J simple node property [" + propName + "] with value=[" + newVal + "]");
                return new ShouldProceedOrReturn(true,newVal);
            }

            FieldAccessor accessor = fieldAccessorFactory.forField(field);
            if (accessor == null) {
                log.info("Ignored SET " + field + ": " + field.getType().getName() + " not primitive, convertable, or GraphEntity");
                return new ShouldProceedOrReturn(true,newVal);
            }
            log.info("SET " + field + " -> Neo4J relationship with value=[" + newVal + "]");
            Object result = accessor.setValue(entity, newVal);
            return new ShouldProceedOrReturn(true,result);
        } catch(NotInTransactionException e) {
            throw new InvalidDataAccessResourceUsageException("Not in a Neo4j transaction.", e);
        }
    }
    Object around(NodeBacked entity): entityFieldGet(entity) {
        FieldSignature fieldSignature = (FieldSignature) thisJoinPoint.getSignature();
        Field f = fieldSignature.getField();

        if (!transactionIsRunning()) {
            log.warn("Outside of transaction, GET value from field "+f+" has node "+entity.hasUnderlyingNode()+" dirty "+entity.isDirty(f)+" "+entity.dump());
            if (!entity.hasUnderlyingNode() || (entity.isDirty(f))) {
                log.warn("Outside of transaction, GET value from field "+f);
                return proceed(entity);
            }
        }
        log.trace("Inside of transaction, GET-FLUSH to field "+f+" has node "+entity.hasUnderlyingNode()+" dirty "+entity.isDirty()+" "+entity.dump());

        flushDirty(entity);

        ShouldProceedOrReturn shouldProceedOrReturn=getNodePropertyOrRelationship(f,entity);
        if (shouldProceedOrReturn.proceed) {
            return proceed(entity);
        } else {
            return shouldProceedOrReturn.value;
        }
    }

    Object around(NodeBacked entity, Object newVal) : entityFieldSet(entity, newVal) {
        FieldSignature fieldSignature=(FieldSignature) thisJoinPoint.getSignature();
        Field f = fieldSignature.getField();
        if (!transactionIsRunning()) {
            log.warn("Outside of transaction, SET value "+newVal+" to field "+f+" has node "+entity.hasUnderlyingNode()+" dirty "+entity.isDirty(f));
            if (!entity.isDirty(f)) {
                Object existingValue;
                if (entity.hasUnderlyingNode()) existingValue = getNodePropertyOrRelationship(f, entity).value;
                else {
                    existingValue = getValueFromEntity(f, entity);
                    if (existingValue==null) existingValue=getDefaultValue(f.getType());
                }
                entity.addDirty(f,existingValue);
            }
            log.warn("Outside of transaction, SET2 value "+newVal+" to field "+f+" has node "+entity.hasUnderlyingNode()+" dirty "+entity.isDirty(f)+" "+entity.dump());
            return proceed(entity, newVal);
        }
        log.trace("Inside of transaction, FLUSH-SET value "+newVal+" to field "+f+" has node "+entity.hasUnderlyingNode()+" dirty "+entity.isDirty()+" "+entity.dump());
        flushDirty(entity);

        ShouldProceedOrReturn shouldProceedOrReturn=setNodePropertyOrRelationship(f,entity,newVal);
        if (shouldProceedOrReturn.proceed) {
            return proceed(entity,shouldProceedOrReturn.value);
        } else {
            return shouldProceedOrReturn.value;
        }
	}

	private boolean isNeo4jPropertyType(Class<?> fieldType) {
		// todo: add array support
		return fieldType.isPrimitive()
	  		|| (fieldType.isArray() && !fieldType.getComponentType().isArray() && isNeo4jPropertyType(fieldType.getComponentType()))
	  		|| fieldType.equals(String.class)
	  		|| fieldType.equals(Character.class)
	  		|| fieldType.equals(Boolean.class)
	  		|| (fieldType.getName().startsWith("java.lang") && Number.class.isAssignableFrom(fieldType));
	}

	private boolean isSerializableField(Field field) {
		return !DelegatingFieldAccessorFactory.isRelationshipField(field) && conversionService.canConvert(field.getType(), String.class);
	}
	
	private boolean isDeserializableField(Field field) {
		return !DelegatingFieldAccessorFactory.isRelationshipField(field) && conversionService.canConvert(String.class, field.getType());
	}
	
	private Object serializePropertyValue(Object newVal, Class<?> fieldType) {
		if (isNeo4jPropertyType(fieldType)) {
			return newVal;
		}
		return conversionService.convert(newVal, String.class);
	}
	
	private Object deserializePropertyValue(Object value, Class<?> fieldType) {
		if (isNeo4jPropertyType(fieldType)) {
			return value;
		}
		return conversionService.convert(value, fieldType);
	}
	
    // todo @property annotation
    // todo fieldlist in @graphentity
    private boolean isIndexedProperty(Field field) {
        final GraphEntity graphEntity = field.getDeclaringClass().getAnnotation(GraphEntity.class);
        if (graphEntity != null && graphEntity.fullIndex()) return true;
        final GraphEntityProperty graphEntityProperty = field.getAnnotation(GraphEntityProperty.class);
        return graphEntityProperty!=null && graphEntityProperty.index();
    }

    public static class NodeBackedNodeIterableWrapper extends IterableWrapper<NodeBacked, Node> {
        private final Class<? extends NodeBacked> targetType;

        public NodeBackedNodeIterableWrapper(Traverser traverser, Class<? extends NodeBacked> targetType) {
            super(traverser.nodes());
            this.targetType = targetType;
        }

        @Override
        protected NodeBacked underlyingObjectToObject(Node node) {
            return Neo4jNodeBacking.aspectOf().graphEntityInstantiator.createEntityFromState(node,targetType);
        }
    }
}
